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

    def size
      rows, cols = TTY::Screen.size
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
          @painter.invalidate
        end
        render
        key = @reader.read_keypress(echo: false, raw: false, nonblock: true)
        handle_key(key) if key
      end
    end

    def render
      now = Time.now
      sections = filtered(@store.sections(now))
      width, height = size
      ensure_selection(sections)
      peek_lines = nil
      peek_title = nil
      if @peek_on && @selected.is_a?(String)
        row = sections.all.find { |r| r.id == @selected }
        peek_lines = peek_body(row)
        peek_title = row&.label || @selected
      end
      frame = @renderer.frame(
        sections, width: width, height: height, now: now,
        selected: @selected, top: @top, settled_expanded: @settled_expanded,
        peek: peek_lines, peek_title: peek_title, modal: modal_lines(width),
        status: status_text(now), filter: @filter
      )
      @items = frame.items.compact
      @top = frame.top
      @painter.paint(frame.lines)
    end

    def status_text(now)
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
      @selected = keys.first
      @peek.want(@selected) if @selected.is_a?(String)
    end

    def selectable_keys(sections)
      keys = []
      sections.each_section do |name, rows|
        if name == :settled && !@settled_expanded
          keys << :settled unless rows.empty?
        else
          rows.each { |r| keys << r.id if r.selectable? }
        end
      end
      keys
    end

    def peek_body(row)
      return ["(nothing selected)"] unless row
      s = row.session
      head = [
        "#{s.state}#{" · #{s.status}" if s.status}#{" · #{s.waiting_for}" if s.waiting_for}",
        s.cwd.to_s,
        "id #{s.id} · session #{s.session_id}",
        "started #{s.started_at&.strftime("%Y-%m-%d %H:%M")}",
        ""
      ]
      body = @peek.cached(s.id) || ["(loading…)"]
      head + body
    end

    # ----- keys -------------------------------------------------------------

    def key_name(key)
      @reader.console.keys[key] || key
    end

    def handle_key(key)
      name = key_name(key)
      return handle_modal_key(name, key) if @modal
      return handle_filter_key(name, key) if @filter_editing

      case name
      when :ctrl_c, "q" then @quit = true
      when :up, "k" then move(-1)
      when :down, "j" then move(1)
      when "g" then move(-1_000_000)
      when "G" then move(1_000_000)
      when :return, :enter then activate
      when "s" then open_snooze_menu
      when "u" then wake_selected
      when "x" then open_stop_confirm
      when "a" then open_alias_editor
      when "R" then Thread.new { poll_once }
      when :tab then toggle_peek
      when "/" then start_filter
      when :escape then clear_filter
      end
    end

    def move(delta)
      return if @items.nil? || @items.empty?
      keys = selectable_keys(filtered(@store.sections))
      idx = keys.index(@selected) || 0
      @selected = keys[(idx + delta).clamp(0, keys.size - 1)]
      @peek.want(@selected) if @selected.is_a?(String)
    end

    def activate
      case @selected
      when :settled then @settled_expanded = true
      when String then attach(@selected)
      end
    end

    def toggle_peek
      @peek_on = !@peek_on
      @peek.want(@selected) if @peek_on && @selected.is_a?(String)
      @painter.invalidate
    end

    def wake_selected
      @store.wake(@selected) if @selected.is_a?(String)
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
      return unless @selected.is_a?(String)
      @modal = {kind: :snooze, id: @selected}
    end

    def open_stop_confirm
      return unless @selected.is_a?(String)
      @modal = {kind: :stop, id: @selected}
    end

    def open_alias_editor
      return unless @selected.is_a?(String)
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

    # ----- filter -----------------------------------------------------------

    def start_filter
      @filter ||= +""
      @filter_editing = true
    end

    def clear_filter
      @filter = nil
      @filter_editing = false
    end

    def handle_filter_key(name, key)
      case name
      when :escape then clear_filter
      when :return, :enter then @filter_editing = false
      when :backspace, :ctrl_h
        @filter = @filter[0...-1]
      else
        @filter << key if key.is_a?(String) && key.match?(/\A[[:print:]]\z/)
      end
    end
  end
end
