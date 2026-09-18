# frozen_string_literal: true

require "io/console"
require "tty-cursor"
require "tty-reader"
require "tty-screen"
require "tty-box"
require_relative "agents_client"
require_relative "debug"
require_relative "store"
require_relative "renderer"
require_relative "logs"
require_relative "peek"
require_relative "keymap"
require_relative "mouse"
require_relative "new_session_form"
require_relative "paste"
require_relative "pull_requests"
require_relative "poller"

module ClaudeInbox
  # Owns the terminal and the key loop. The only class allowed to spawn a
  # child process that takes over the terminal.
  class App
    ALT_ON = "\e[?1049h"
    ALT_OFF = "\e[?1049l"
    # Alternate scroll mode: while the alt screen is up the terminal turns
    # wheel ticks into cursor keys, so a scroll moves the selection instead of
    # dragging the scrollback we are covering into view. Terminals that don't
    # know the mode ignore it and keep scrolling their own history.
    WHEEL_KEYS_ON = "\e[?1007h"
    WHEEL_KEYS_OFF = "\e[?1007l"
    # Real mouse reporting: button events plus the SGR encoding, so clicks
    # and wheel ticks arrive as escape sequences we parse ourselves (Mouse)
    # instead of the terminal only ever translating the wheel to arrow
    # keys. Terminals that don't understand either mode just ignore it and
    # fall back to WHEEL_KEYS_ON's translation, or their own scrollback.
    MOUSE_ON = "\e[?1000h\e[?1006h"
    MOUSE_OFF = "\e[?1006l\e[?1000l"
    # Bracketed paste: what is pasted arrives fenced off from what is typed
    # (Paste), and a pasted image, which has no text, arrives as an empty
    # fence rather than not at all.
    PASTE_ON = "\e[?2004h"
    PASTE_OFF = "\e[?2004l"

    SNOOZE_MENU = [
      ["1", "15 minutes", :m15],
      ["2", "1 hour", :h1],
      ["3", "tomorrow 9am", :tomorrow_9am],
      ["4", "until I wake it", :until_woken]
    ].freeze

    # The reaper defaults to off. It is the only thing here that deletes a
    # session, so switching it on is `bin/claude-inbox`'s job and nothing
    # reaches it by forgetting an argument.
    def initialize(client: AgentsClient.new, store: Store.new, pull_requests: PullRequests.new, jobs_dir: JobState::DEFAULT_DIR,
      reaper: Reaper.disabled, out: $stdout, input: $stdin, color: true)
      @client = client
      @store = store
      @out = out
      @input = input
      @color = color
      @renderer = Renderer.new(color: color)
      @painter = Painter.new(out)
      @reader = TTY::Reader.new(input: input, output: out, interrupt: :noop)
      @queue = Queue.new
      @poller = Poller.new(client: client, store: store, pull_requests: pull_requests, jobs_dir: jobs_dir,
        reaper: reaper, queue: @queue)
      @selected = nil
      @row_items = []
      @list_width = nil
      @top = 0
      @expanded = Hash.new(false)
      @keymap = Keymap.new
      @paste = Paste.new
      @tick = 0
      @modal = nil
      @filter = nil
      @status = "starting…"
      @last_poll = nil
      @quit = false
      @resize = false
      @restored = true
    end

    def run
      @booted_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      install_traps
      enter_screen
      @poller.start
      @logs = Logs.new(@client, @queue)
      @peek = Peek.new(@logs)
      main_loop
    ensure
      @poller.stop
      @logs&.stop
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
      @out.print ALT_ON, WHEEL_KEYS_ON, MOUSE_ON, PASTE_ON, TTY::Cursor.hide, TTY::Cursor.clear_screen
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
      @out.print TTY::Cursor.show, PASTE_OFF, MOUSE_OFF, WHEEL_KEYS_OFF, ALT_OFF
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

    # Runs a block off the main thread; a failure lands in the status line
    # rather than killing the thread silently.
    def in_background
      Thread.new do
        yield
      rescue => e
        @queue << [:error, e.message]
      end
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
        when :notice then notice(rest[0])
        when :attach then attach(rest[0])
        end
      end
    rescue ThreadError
      nil
    end

    # ----- main loop --------------------------------------------------------

    def main_loop
      until @quit
        drain_queue
        @logs.tick
        if @resize
          @resize = false
          @size = nil
          @painter.invalidate
        end
        render
        key = @reader.read_keypress(echo: false, raw: false, nonblock: true)
        handle_input(key) if key
      end
    end

    def handle_input(raw)
      @paste.feed(raw).each do |kind, text|
        next handle_paste(text) if kind == :paste
        events = Mouse.events(text)
        next events.each { |e| handle_mouse(e) } if events.any?
        split_keys(text).each { |k| handle_key(k) }
      end
    end

    # The form takes a paste whole, images included; the one-line editors
    # take it as typing, so a pasted PR URL lands where it should.
    def handle_paste(text)
      return @modal[:form].paste(text) if @modal && @modal[:kind] == :new
      text.each_char { |c| handle_key(c) }
    end

    def render
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      now = Time.now
      sections = filtered(@store.sections(now))
      width, height = size
      ensure_selection(sections)
      peek = @peek.view(sections.row(@selected), height)
      @tick += 1
      frame = @renderer.frame(
        sections, width: width, height: height, now: now,
        selected: @selected, top: @top, expanded: @expanded,
        peek: peek&.lines, peek_title: peek&.title, peek_subtitle: peek&.subtitle,
        modal: modal_lines(width), screen: screen_lines(width, height), status: status_text(now),
        filter: @filter, filter_editing: @filter_editing, command: @command, tick: @tick / 2,
        loading: loading_for
      )
      @items = frame.items.compact
      @row_items = frame.items
      @list_width = frame.list_width
      @top = frame.top
      @painter.paint(frame.lines)
      dt = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      Debug.log("render #{(dt * 1000).round}ms") if dt > 0.05
    end

    # Seconds spent waiting for the first poll; nil once one has landed, or
    # failed — a failure has its own line in the header and the empty state
    # already says how to retry.
    def loading_for
      return nil if @last_poll || @error || !@booted_at
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - @booted_at
    end

    def status_text(now)
      return @notice[0] if @notice && now < @notice[1]
      return "⚠ #{@error}" if @error
      return "polling…" unless @last_poll
      "⟳ #{Text.age(now - @last_poll)} ago"
    end

    def filtered(sections = @store.sections) = sections.matching(@filter)

    def ensure_selection(sections)
      keys = sections.selectable_keys(@expanded)
      if @pending_select && keys.include?(@pending_select)
        select(@pending_select)
        @pending_select = nil
        return
      end
      return if keys.include?(@selected)
      select(keys.first)
    end

    def select(key)
      @selected = key
      @peek.select(key, selected_session)
    end

    def session_for(key) = @store.sessions.find { |s| s.key == key }

    def selected_session = session_for(@selected)

    # True when the selection is a background session we can act on.
    def actionable_id?(key) = session_for(key)&.actionable?

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

    def notice(msg)
      @notice = [msg, Time.now + 4]
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

    # A modal or an open filter/command line already claims every keypress
    # ahead of the normal action table (see handle_key); mouse input defers
    # to the same rule rather than reaching past whatever has focus.
    def handle_mouse(event)
      return if @modal || @filter_editing || @command
      case event.kind
      when :click then click_row(event.row, event.col)
      when :scroll_up then perform(:up)
      when :scroll_down then perform(:down)
      end
    end

    # Clicking a row selects it and attaches, same as landing on it with
    # j/k and pressing Enter — activate already knows how to expand a fold
    # or refuse a terminal/remote row, so this doesn't repeat that.
    def click_row(row, col)
      return if @list_width && col > @list_width
      item = row_item_at(row)
      return unless item
      select(item.key)
      activate
    end

    # The wrapped detail line under a two-line row ("↳ ~/code/x") carries
    # no item of its own; a click there resolves to the row above it.
    def row_item_at(row)
      idx = row - 1
      @row_items[idx] || (@row_items[idx - 1] if idx > 0 && @row_items[idx - 1]&.kind == :row)
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
      when :peek_down then @peek.scroll(-1)
      when :peek_up then @peek.scroll(1)
      when :activate then activate
      when :collapse then collapse
      when :fold_open then set_expanded(true)
      when :fold_close then set_expanded(false)
      when :fold_toggle then set_expanded(!@expanded[current_fold_section])
      when :snooze then open_snooze_menu
      when :wake then wake_selected
      when :toggle_pin then toggle_pin_selected
      when :settle then settle_selected
      when :alias then open_alias_editor
      when :link_pr then open_pr_editor
      when :open_pr then open_pr
      when :stop then open_confirm(:stop)
      when :delete then open_confirm(:delete)
      when :refresh then @poller.soon
      when :toggle_peek then toggle_peek
      when :new_session then open_new_session
      when :filter then start_filter
      when :command then @command = +""
      when :escape then clear_filter
      end
    end

    def page = [size[1] - 2, 1].max

    def move(delta)
      return if @items.nil? || @items.empty?
      keys = filtered.selectable_keys(@expanded)
      idx = keys.index(@selected) || 0
      select(keys[(idx + delta).clamp(0, keys.size - 1)])
    end

    # Tab / Shift-Tab: first selectable row of the next / previous section.
    def jump_section(dir)
      sections = filtered
      # A row's id rather than its key, kept as it was: a section headed by an
      # interactive row (no id) contributes nil here and Tab passes it over.
      firsts = sections.heads(@expanded).map { |name, row| row ? row.id : name }
      return if firsts.empty?
      current = sections.section_of(@selected)
      order = Store::SECTIONS.select { |k| firsts.any? { |f| sections.section_of(f) == k } }
      idx = order.index(current) || -1
      target = order[(idx + dir) % order.size]
      select(firsts.find { |f| sections.section_of(f) == target })
    end

    # The foldable section the cursor is currently on or inside, if any.
    def current_fold_section
      name = filtered.section_of(@selected)
      name if Store::FOLDABLE_SECTIONS.include?(name)
    end

    def set_expanded(value, name: current_fold_section)
      @expanded[name] = value if name
    end

    # vim-ish "h": close whatever is open, innermost first.
    def collapse
      if @peek.open? then @peek.close
      elsif (name = current_fold_section) && @expanded[name] then @expanded[name] = false
      end
      @painter.invalidate
    end

    def activate
      return @expanded[@selected] = true if Store::FOLDABLE_SECTIONS.include?(@selected)
      attach(@selected) if require_actionable
    end

    def toggle_peek
      @peek.toggle
      @painter.invalidate
    end

    def wake_selected
      @store.wake(@selected) if require_storable
    end

    def toggle_pin_selected
      @store.toggle_pin(@selected) if require_storable
    end

    def settle_selected
      return unless require_storable
      @store.settle(@selected)
      notice("settled — u brings it back")
    end

    # ----- attach handoff ---------------------------------------------------

    def attach(id)
      @store.acknowledge(id)
      @poller.pause
      restore_screen
      @out.print TTY::Cursor.clear_screen
      @out.flush
      @client.attach(id)
    ensure
      enter_screen
      @poller.resume
      @poller.soon
    end

    # ----- modals -----------------------------------------------------------

    def open_snooze_menu
      return unless require_storable
      @modal = {kind: :snooze, id: @selected}
    end

    def open_confirm(kind)
      return unless require_actionable
      @modal = {kind: kind, id: @selected}
    end

    def open_alias_editor
      return unless require_storable
      current = @store.alias_for(@selected) || ""
      @modal = {kind: :alias, id: @selected, buffer: +current}
    end

    def open_pr_editor
      return unless require_storable
      current = @store.pr_for(@selected) || selected_session&.pr&.url || ""
      @modal = {kind: :pr, id: @selected, buffer: +current}
    end

    # Hands the first PR to the OS browser opener.
    def open_pr
      pr = selected_session&.pr
      return notice("no pull request linked — P sets one") unless pr
      opener = RUBY_PLATFORM.include?("darwin") ? "open" : "xdg-open"
      notice("opening #{pr.short}")
      Thread.new { Subprocess.capture(opener, pr.url) }
    end

    def open_new_session
      cwd = selected_session&.cwd || Dir.pwd
      @modal = {kind: :new, form: NewSessionForm.new(cwd: cwd, pastel: Pastel.new(enabled: @color))}
    end

    # `attach:` hands the terminal over as soon as the session starts. Without
    # it we stay in the inbox and poll, so the new row shows up right away
    # rather than at the next tick.
    def start_session(form, attach:)
      v = form.values
      notice("starting session…")
      in_background do
        id = @client.spawn(**v)
        notice("started #{id}")
        @pending_select = id
        attach ? @queue << [:attach, id] : @poller.once
      end
    end

    def screen_lines(width, height)
      return nil unless @modal && @modal[:kind] == :new
      form = @modal[:form]
      {lines: form.screen(width, height - 2), footer: form.footer}
    end

    def modal_lines(width)
      return nil unless @modal && @modal[:kind] != :new
      content =
        case @modal[:kind]
        when :snooze
          SNOOZE_MENU.map { |k, label, _| "  #{k}  #{label}" } + ["", "  esc  cancel"]
        when :stop
          ["  Stop session #{@modal[:id]}?", "", "  y  stop it", "  esc  cancel"]
        when :delete
          ["  Delete session #{@modal[:id]}?", "  Its worktree and conversation", "  go with it.",
            "", "  y  delete it", "  esc  keep it"]
        when :alias
          ["  New alias:", "", "  > #{@modal[:buffer]}_", "", "  ⏎ save · esc cancel"]
        when :pr
          ["  Pull request URL (empty clears):", "", "  > #{@modal[:buffer]}_", "", "  ⏎ save · esc cancel"]
        end
      title = {snooze: " Snooze ", stop: " Stop ", delete: " Delete ", alias: " Alias ", pr: " Pull request "}[@modal[:kind]]
      TTY::Box.frame(content.join("\n"), title: {top_left: title}, padding: [0, 1], width: [width - 4, 44].min)
        .split("\n")
    end

    def handle_modal_key(name, key)
      case @modal[:kind]
      when :new
        form = @modal[:form]
        case form.press(name, key)
        when :cancel then @modal = nil
        when :start
          @modal = nil
          start_session(form, attach: false)
        when :start_and_attach
          @modal = nil
          start_session(form, attach: true)
        end
      when :snooze
        if name == :escape || name == "q"
          @modal = nil
        elsif (entry = SNOOZE_MENU.find { |k, _, _| k == key })
          @store.snooze(@modal[:id], entry[2])
          @modal = nil
        end
      when :alias, :pr
        case name
        when :escape then @modal = nil
        when :return, :enter then save_text_modal
        when :backspace, :ctrl_h then @modal[:buffer] = @modal[:buffer][0...-1]
        else @modal[:buffer] << key if key.is_a?(String) && key.match?(/\A[[:print:]]\z/)
        end
      when :stop, :delete
        if key == "y"
          kind, id = @modal.values_at(:kind, :id)
          @modal = nil
          (kind == :stop) ? stop_session(id) : delete_session(id)
        elsif name == :escape || key == "n" || key == "q"
          @modal = nil
        end
      end
    end

    def stop_session(id)
      in_background do
        @client.stop(id)
        @poller.once
      end
    end

    def delete_session(id)
      notice("deleting #{id}…")
      in_background do
        @client.rm(id)
        @store.forget(id)
        notice("deleted #{id}")
        @poller.once
      end
    end

    def save_text_modal
      value = @modal[:buffer].strip
      if @modal[:kind] == :alias
        @store.set_alias(@modal[:id], value)
      elsif value.empty? || PullRequests.valid_url?(value)
        @store.set_pr(@modal[:id], value)
        @poller.soon
      else
        return notice("that's not a github.com pull request url")
      end
      @modal = nil
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
