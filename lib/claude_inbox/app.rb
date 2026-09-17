# frozen_string_literal: true

require "io/console"
require "tty-cursor"
require "tty-reader"
require "tty-screen"
require "tty-box"
require_relative "agents_client"
require_relative "store"
require_relative "renderer"
require_relative "peek"
require_relative "keymap"

module ClaudeInbox
  # Owns the terminal and the key loop. The only class allowed to spawn a
  # child process that takes over the terminal.
  class App
    POLL_INTERVAL = 4
    ALT_ON = "\e[?1049h"
    ALT_OFF = "\e[?1049l"

    SNOOZE_MENU = [
      ["1", "15 minutes", :m15],
      ["2", "1 hour", :h1],
      ["3", "tomorrow 9am", :tomorrow_9am],
      ["4", "until I wake it", :until_woken]
    ].freeze

    def initialize(client: AgentsClient.new, store: Store.new, out: $stdout, input: $stdin, color: true)
      @client = client
      @store = store
      @out = out
      @input = input
      @renderer = Renderer.new(color: color)
      @painter = Painter.new(out)
      @reader = TTY::Reader.new(input: input, output: out, interrupt: :noop)
      @queue = Queue.new
      @selected = nil
      @top = 0
      @settled_expanded = false
      @peek_on = false
      @peek_offset = 0
      @keymap = Keymap.new
      @tick = 0
      @modal = nil
      @filter = nil
      @status = "starting…"
      @last_poll = nil
      @quit = false
      @resize = false
      @paused = false
      @restored = true
    end

    def run
      install_traps
      enter_screen
      @poller = Thread.new { poll_loop }
      @peek = Peek.new(@client, @queue)
      main_loop
    ensure
      @poller&.kill
      @peek&.stop
      restore_screen
    end

    private

    # ----- terminal ---------------------------------------------------------

    def install_traps
      at_exit { restore_screen }
      %w[INT TERM].each { |sig| trap(sig) { @quit = true } }
      trap("WINCH") { @resize = true } if Signal.list.key?("WINCH")
    end

    def enter_screen
      @out.print ALT_ON, TTY::Cursor.hide, TTY::Cursor.clear_screen
      @out.flush
      @input.raw! if @input.respond_to?(:raw!) && @input.tty?
      @restored = false
      @size = nil
      @painter.invalidate
    end

    def restore_screen
      return if @restored
      @restored = true
      @input.cooked! if @input.respond_to?(:cooked!) && @input.tty?
      @out.print TTY::Cursor.show, ALT_OFF
      @out.flush
    rescue
      nil
    end

    # Cached: querying the terminal can fall back to spawning `tput`, which
    # is far too slow to do on every frame. Refreshed on WINCH and re-entry.
    def size
      @size ||= measure_size
    end

    def measure_size
      rows, cols = begin
        (@out.respond_to?(:winsize) && @out.tty?) ? @out.winsize : TTY::Screen.size
      rescue
        TTY::Screen.size
      end
      [[cols, 40].max, [rows, 8].max]
    end

    # ----- threads ----------------------------------------------------------

    def poll_loop
      loop do
        poll_once unless @paused
        sleep POLL_INTERVAL
      end
    end

    def poll_once
      @queue << [:sessions, @client.list]
    rescue => e
      @queue << [:error, e.message]
    end

    def drain_queue
      until @queue.empty?
        kind, *rest = @queue.pop(true)
        case kind
        when :sessions
          @store.update(rest[0])
          @last_poll = Time.now
          @error = nil
        when :error then @error = rest[0]
        when :peek then @dirty = true
        end
      end
    rescue ThreadError
      nil
    end

    # ----- main loop --------------------------------------------------------

    def main_loop
      until @quit
        drain_queue
        @peek.tick
        if @resize
          @resize = false
          @size = nil
          @painter.invalidate
        end
        render
        key = @reader.read_keypress(echo: false, raw: false, nonblock: true)
        split_keys(key).each { |k| handle_key(k) } if key
      end
    end

    # CLAUDE_INBOX_DEBUG=1 appends slow-frame notes to /tmp/inbox-debug.log.
    def debug(msg)
      return unless ENV["CLAUDE_INBOX_DEBUG"]
      File.write("/tmp/inbox-debug.log", "#{Time.now.strftime("%H:%M:%S.%L")} #{msg}\n", mode: "a")
    end

    def render
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      now = Time.now
      sections = filtered(@store.sections(now))
      width, height = size
      ensure_selection(sections)
      peek_lines = nil
      peek_title = nil
      if @peek_on && @selected.is_a?(String)
        row = sections.all.find { |r| r.key == @selected }
        peek_lines = peek_body(row)
        peek_lines = scrolled(peek_lines, height - 2)
        peek_title = row&.label || @selected
      end
      @tick += 1
      frame = @renderer.frame(
        sections, width: width, height: height, now: now,
        selected: @selected, top: @top, settled_expanded: @settled_expanded,
        peek: peek_lines, peek_title: peek_title, peek_subtitle: peek_subtitle(sections),
        modal: modal_lines(width), status: status_text(now),
        filter: @filter, filter_editing: @filter_editing, command: @command, tick: @tick / 2
      )
      @items = frame.items.compact
      @top = frame.top
      @painter.paint(frame.lines)
      dt = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      debug("render #{(dt * 1000).round}ms") if dt > 0.05
    end

    def status_text(now)
      return @notice[0] if @notice && now < @notice[1]
      return "⚠ #{@error}" if @error
      return "polling…" unless @last_poll
      "⟳ #{Text.age(now - @last_poll)} ago"
    end

    def filtered(sections)
      return sections unless @filter && !@filter.empty?
      q = @filter.downcase
      Store::Sections.new(**Store::SECTIONS.to_h { |k|
        [k, sections[k].select { |r| r.label.downcase.include?(q) || r.session.cwd.to_s.downcase.include?(q) }]
      })
    end

    def ensure_selection(sections)
      keys = selectable_keys(sections)
      return if keys.include?(@selected)
      select(keys.first)
    end

    def select(key)
      @selected = key
      @peek_offset = 0
      @peek.want(key) if actionable_id?(key)
    end

    # True when the selection is a background session we can act on.
    def actionable_id?(key)
      key.is_a?(String) && @store.sessions.any? { |s| s.id == key }
    end

    def selected_session
      @store.sessions.find { |s| s.key == @selected }
    end

    # Guard for attach/stop: refuse politely on a terminal or remote row.
    def require_actionable
      return true if actionable_id?(@selected)
      if (s = selected_session)&.interactive?
        notice(s.remote? ? "that's a remote session — open it at claude.ai/code" : "that's your own terminal — switch to that window")
      end
      false
    end

    # Guard for snooze/wake/alias: anything with a key, since those live in
    # our own store. A terminal you are sitting in is the one exception.
    def require_storable
      return true if @selected.is_a?(String) && !selected_session&.terminal?
      notice("you're in that terminal right now — nothing to snooze") if selected_session&.terminal?
      false
    end

    def selectable_keys(sections)
      keys = []
      sections.each_section do |name, rows|
        if name == :settled && !@settled_expanded
          keys << :settled unless rows.empty?
        else
          rows.each { |r| keys << r.key if r.selectable? }
        end
      end
      keys
    end

    def peek_body(row)
      return ["(nothing selected)"] unless row
      return interactive_note(row.session) if row.session.interactive?
      @peek.cached(row.session.id) || ["(loading…)"]
    end

    TERMINAL_NOTE = "This is a claude you opened in a terminal yourself. The daemon can't attach to it, read its output, or stop it from outside. Switch to that window."
    REMOTE_NOTE = "This is a Remote Control session driven from claude.ai/code. The daemon can't attach to it or read its output from here. Open it in the web or mobile app instead."

    def interactive_note(s)
      [s.remote? ? REMOTE_NOTE : TERMINAL_NOTE, "", "pid #{s.pid} · #{s.cwd}", "session #{s.session_id}"]
    end

    def notice(msg)
      @notice = [msg, Time.now + 4]
    end

    def peek_subtitle(sections)
      row = sections.all.find { |r| r.key == @selected }
      return nil unless row
      s = row.session
      parts = [s.effective_state, s.status, s.waiting_for, s.id, s.started_at&.strftime("started %b %-d %H:%M")].compact
      parts.join(" · ")
    end

    # ----- keys -------------------------------------------------------------

    def key_name(key)
      @reader.console.keys[key] || key
    end

    # tty-reader glues ESC to whatever arrives within 100ms, so a fast
    # "esc :q" comes in as one unknown key "\e:q". Vim hands make that
    # constantly. Unknown ESC-prefixed strings become ESC + the rest.
    def split_keys(key)
      return [key] if key.size <= 1 || @reader.console.keys.key?(key)
      return [key] unless key.start_with?("\e")
      ["\e"] + key[1..].chars
    end

    def handle_key(key)
      name = key_name(key)
      return handle_modal_key(name, key) if @modal
      return handle_line_key(name, key) if @filter_editing || @command

      action = @keymap.press(name, key)
      perform(action) if action
    end

    def perform(action)
      case action
      when :quit then @quit = true
      when :up then move(-1)
      when :down then move(1)
      when :top then move(-1_000_000)
      when :bottom then move(1_000_000)
      when :half_page_down then move(page / 2)
      when :half_page_up then move(-(page / 2))
      when :page_down then move(page)
      when :page_up then move(-page)
      when :next_section then jump_section(1)
      when :prev_section then jump_section(-1)
      when :peek_down then @peek_offset = [@peek_offset - 1, 0].max
      when :peek_up then @peek_offset += 1
      when :activate then activate
      when :collapse then collapse
      when :fold_open then @settled_expanded = true
      when :fold_close then @settled_expanded = false
      when :fold_toggle then @settled_expanded = !@settled_expanded
      when :snooze then open_snooze_menu
      when :wake then wake_selected
      when :alias then open_alias_editor
      when :stop then open_stop_confirm
      when :refresh then Thread.new { poll_once }
      when :toggle_peek then toggle_peek
      when :filter then start_filter
      when :command then @command = +""
      when :escape then clear_filter
      end
    end

    def page = [size[1] - 2, 1].max

    def move(delta)
      return if @items.nil? || @items.empty?
      keys = selectable_keys(filtered(@store.sections))
      idx = keys.index(@selected) || 0
      select(keys[(idx + delta).clamp(0, keys.size - 1)])
    end

    # Tab / Shift-Tab: first selectable row of the next / previous section.
    def jump_section(dir)
      sections = filtered(@store.sections)
      firsts = []
      sections.each_section do |name, rows|
        if name == :settled && !@settled_expanded
          firsts << :settled unless rows.empty?
        else
          first = rows.find(&:selectable?)
          firsts << first.id if first
        end
      end
      return if firsts.empty?
      current = section_of(@selected, sections)
      order = Store::SECTIONS.select { |k| firsts.any? { |f| section_of(f, sections) == k } }
      idx = order.index(current) || -1
      target = order[(idx + dir) % order.size]
      select(firsts.find { |f| section_of(f, sections) == target })
    end

    def section_of(key, sections)
      return :settled if key == :settled
      sections.each_section { |name, rows| return name if rows.any? { |r| r.key == key } }
      nil
    end

    # vim-ish "h": close whatever is open, innermost first.
    def collapse
      if @peek_on then @peek_on = false
      elsif @settled_expanded then @settled_expanded = false
      end
      @painter.invalidate
    end

    # Peek lines are shown tail-first; offset scrolls back into history.
    def scrolled(lines, view_h)
      return lines if @peek_offset.zero?
      max_off = [lines.size - view_h, 0].max
      @peek_offset = [@peek_offset, max_off].min
      lines[0, lines.size - @peek_offset]
    end

    def activate
      return @settled_expanded = true if @selected == :settled
      attach(@selected) if require_actionable
    end

    def toggle_peek
      @peek_on = !@peek_on
      @peek.want(@selected) if @peek_on && actionable_id?(@selected)
      @painter.invalidate
    end

    def wake_selected
      @store.wake(@selected) if require_storable
    end

    # ----- attach handoff ---------------------------------------------------

    def attach(id)
      @paused = true
      restore_screen
      @out.print TTY::Cursor.clear_screen
      @out.flush
      @client.attach(id)
    ensure
      enter_screen
      @paused = false
      Thread.new { poll_once }
    end

    # ----- modals -----------------------------------------------------------

    def open_snooze_menu
      return unless require_storable
      @modal = {kind: :snooze, id: @selected}
    end

    def open_stop_confirm
      return unless require_actionable
      @modal = {kind: :stop, id: @selected}
    end

    def open_alias_editor
      return unless require_storable
      current = @store.entry(@selected)&.dig("alias") || ""
      @modal = {kind: :alias, id: @selected, buffer: +current}
    end

    def modal_lines(width)
      return nil unless @modal
      content =
        case @modal[:kind]
        when :snooze
          SNOOZE_MENU.map { |k, label, _| "  #{k}  #{label}" } + ["", "  esc  cancel"]
        when :stop
          ["  Stop session #{@modal[:id]}?", "", "  y  stop it", "  esc  cancel"]
        when :alias
          ["  New alias:", "", "  > #{@modal[:buffer]}_", "", "  ⏎ save · esc cancel"]
        end
      title = {snooze: " Snooze ", stop: " Stop ", alias: " Alias "}[@modal[:kind]]
      TTY::Box.frame(content.join("\n"), title: {top_left: title}, padding: [0, 1], width: [width - 4, 44].min)
        .split("\n")
    end

    def handle_modal_key(name, key)
      case @modal[:kind]
      when :snooze
        if name == :escape || name == "q"
          @modal = nil
        elsif (entry = SNOOZE_MENU.find { |k, _, _| k == key })
          @store.snooze(@modal[:id], entry[2])
          @modal = nil
        end
      when :alias
        case name
        when :escape then @modal = nil
        when :return, :enter
          @store.set_alias(@modal[:id], @modal[:buffer].strip)
          @modal = nil
        when :backspace, :ctrl_h then @modal[:buffer] = @modal[:buffer][0...-1]
        else @modal[:buffer] << key if key.is_a?(String) && key.match?(/\A[[:print:]]\z/)
        end
      when :stop
        if key == "y"
          id = @modal[:id]
          @modal = nil
          Thread.new do
            @client.stop(id)
            poll_once
          rescue => e
            @queue << [:error, e.message]
          end
        elsif name == :escape || key == "n"
          @modal = nil
        end
      end
    end

    # ----- filter / command line ---------------------------------------------

    def start_filter
      @filter ||= +""
      @filter_editing = true
    end

    def clear_filter
      @filter = nil
      @filter_editing = false
      @command = nil
    end

    def handle_line_key(name, key)
      buffer = @command || @filter
      case name
      when :escape
        @command ? @command = nil : clear_filter
      when :return, :enter
        if @command
          action = Keymap.command(@command)
          @command = nil
          perform(action) if action
        else
          @filter_editing = false
        end
      when :backspace, :ctrl_h
        if buffer.empty?
          @command ? @command = nil : clear_filter
        else
          buffer.slice!(-1)
        end
      else
        buffer << key if key.is_a?(String) && key.match?(/\A[[:print:]]\z/)
      end
    end
  end
end
