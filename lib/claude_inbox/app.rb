# frozen_string_literal: true

require "tty-reader"
require_relative "agents_client"
require_relative "debug"
require_relative "dialog"
require_relative "text_buffer"
require_relative "store"
require_relative "renderer"
require_relative "terminal"
require_relative "logs"
require_relative "peek"
require_relative "keymap"
require_relative "mouse"
require_relative "new_session_form"
require_relative "paste"
require_relative "pull_requests"
require_relative "poller"
require_relative "rate_limits"

module ClaudeInbox
  # Owns the terminal and the key loop. The only class allowed to spawn a
  # child process that takes over the terminal.
  class App
    # The reaper defaults to off. It is the only thing here that deletes a
    # session, so switching it on is `bin/claude-inbox`'s job and nothing
    # reaches it by forgetting an argument.
    def initialize(client: AgentsClient.new, store: Store.new, pull_requests: PullRequests.new,
      rate_limits: RateLimits.new, reaper: Reaper.disabled, out: $stdout, input: $stdin, color: true,
      terminal: Terminal.new(out, input))
      @client = client
      @store = store
      @rate_limits = rate_limits
      @terminal = terminal
      @color = color
      @renderer = Renderer.new(color: color)
      @reader = TTY::Reader.new(input: input, output: out, interrupt: :noop)
      @queue = Queue.new
      @poller = Poller.new(client: client, store: store, pull_requests: pull_requests,
        reaper: reaper, queue: @queue)
      @logs = Logs.new(client)
      @peek = Peek.new(@logs)
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
      @last_poll = nil
      @quit = false
      @resize = false
    end

    def run
      @booted_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      install_traps
      @terminal.enter
      @poller.start
      @logs.start
      main_loop
    ensure
      @poller.stop
      @logs.stop
      @terminal.restore
    end

    def step(input = nil)
      drain_queue
      @logs.tick
      if @resize
        @resize = false
        @terminal.resized
      end
      render
      handle_input(input) if input
    end

    private

    def install_traps
      at_exit { @terminal.restore }
      %w[INT TERM].each { |sig| trap(sig) { @quit = true } }
      trap("WINCH") { @resize = true } if Signal.list.key?("WINCH")
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
        when :select then @pending_select = rest[0]
        when :attach then attach(rest[0])
        when :form_started then @modal = nil if @modal.equal?(rest[0])
        when :form_failed then form_failed(*rest)
        end
      end
    rescue ThreadError
      nil
    end

    # ----- main loop --------------------------------------------------------

    def main_loop
      step(@reader.read_keypress(echo: false, raw: false, nonblock: true)) until @quit
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
      return @modal.paste(text) if @modal.is_a?(NewSessionForm)
      text.each_char { |c| handle_key(c) }
    end

    def render
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      now = Time.now
      sections = filtered(@store.sections(now))
      width, height = @terminal.size
      ensure_selection(sections)
      @tick += 1
      view = Renderer::View.new(
        width: width, height: height, now: now, selected: @selected&.key, top: @top, expanded: @expanded,
        peek: @peek.view(sections.row(@selected), height), modal: modal_lines(width), screen: screen_lines(width, height),
        status: status_text(now), usage: @rate_limits.windows(now), filter: @filter, filter_editing: @filter_editing,
        tick: @tick / 2, loading: loading_for
      )
      frame = @renderer.frame(sections, view)
      @row_items = frame.items
      @list_width = frame.list_width
      @top = frame.top
      @terminal.paint(frame.lines)
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
      "polling…" unless @last_poll
    end

    def filtered(sections = @store.sections) = sections.matching(@filter&.to_s)

    def ensure_selection(sections)
      stops = sections.selections(@expanded)
      pending = @pending_select && Store::Selection.row(@pending_select)
      if pending && stops.include?(pending)
        select(pending)
        @pending_select = nil
        return
      end
      return if stops.include?(@selected)
      select(stops.first)
    end

    def select(selection)
      @selected = selection
      @peek.select(selection, selected_session)
    end

    def session_for(key) = @store.sessions.find { |s| s.key == key }

    def selected_session = session_for(@selected&.key)

    # Guard for attach/stop: refuse politely on a terminal or remote row.
    def require_actionable
      return true if selected_session&.actionable?
      if (s = selected_session)&.interactive?
        notice(s.remote? ? "that's a remote session — Enter adopts it, w opens it at claude.ai/code" : "that's your own terminal — switch to that window")
      end
      false
    end

    # Guard for snooze/wake/alias: anything with a key, since those live in
    # our own store. A terminal you are sitting in is the one exception.
    def require_storable
      return true if @selected&.row? && !selected_session&.terminal?
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
    # "esc gg" comes in as one unknown key "\egg". Vim hands make that
    # constantly. Unknown ESC-prefixed strings become ESC + the rest.
    def split_keys(key)
      return [key] if key.size <= 1 || @reader.console.keys.key?(key)
      return [key] unless key.start_with?("\e")
      ["\e"] + key[1..].chars
    end

    def handle_key(key)
      name = key_name(key)
      return handle_modal_key(name, key) if @modal
      return handle_line_key(name, key) if @filter_editing

      action = @keymap.press(name, key)
      perform(action) if action
    end

    # A modal or an open filter line already claims every keypress ahead of
    # the normal action table (see handle_key); mouse input defers to the
    # same rule rather than reaching past whatever has focus.
    def handle_mouse(event)
      return if @modal || @filter_editing
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
      select(item.selection)
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
      when :open_remote then open_remote
      when :stop then open_confirm(:stop)
      when :delete then open_confirm(:delete)
      when :refresh then @poller.soon
      when :toggle_peek then toggle_peek
      when :new_session then open_new_session
      when :filter then start_filter
      when :escape then clear_filter
      end
    end

    def page = [@terminal.size[1] - 2, 1].max

    def move(delta)
      stops = filtered.selections(@expanded)
      return if stops.empty?
      idx = stops.index(@selected) || 0
      select(stops[(idx + delta).clamp(0, stops.size - 1)])
    end

    # Tab / Shift-Tab: first selectable row of the next / previous section.
    def jump_section(dir)
      sections = filtered
      heads = sections.heads(@expanded)
      return if heads.empty?
      current = sections.section_of(@selected)
      idx = heads.index { |name, _| name == current } || -1
      select(heads[(idx + dir) % heads.size].last)
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
      @terminal.invalidate
    end

    def activate
      return @expanded[@selected.key] = true if @selected&.fold?
      return @modal = Dialog::Confirm.new(:adopt, @selected.key) if selected_session&.remote?
      attach(@selected.key) if require_actionable
    end

    def toggle_peek
      @peek.toggle
      @terminal.invalidate
    end

    def wake_selected
      @store.wake(@selected.key) if require_storable
    end

    def toggle_pin_selected
      @store.toggle_pin(@selected.key) if require_storable
    end

    def settle_selected
      return unless require_storable
      @store.settle(@selected.key)
      notice("settled — u brings it back")
    end

    def attach(id)
      @store.acknowledge(id)
      @poller.pause
      @terminal.release { @client.attach(id) }
    ensure
      @poller.resume
    end

    # ----- modals -----------------------------------------------------------

    def open_snooze_menu
      return unless require_storable
      @modal = Dialog::Snooze.new(@selected.key)
    end

    def open_confirm(kind)
      return unless require_actionable
      @modal = Dialog::Confirm.new(kind, @selected.key)
    end

    def open_alias_editor
      return unless require_storable
      current = @store.alias_for(@selected.key) || ""
      @modal = Dialog::Prompt.new(:alias, @selected.key, current)
    end

    def open_pr_editor
      return unless require_storable
      current = @store.pr_for(@selected.key) || selected_session&.pr&.url || ""
      @modal = Dialog::Prompt.new(:pr, @selected.key, current)
    end

    def open_pr
      pr = selected_session&.pr
      return notice("no pull request linked — P sets one") unless pr
      open_in_browser(pr.url, pr.short)
    end

    def open_remote
      url = selected_session&.remote_url
      return notice("no claude.ai/code page for this session") unless url
      open_in_browser(url, "claude.ai/code")
    end

    def open_in_browser(url, what)
      opener = RUBY_PLATFORM.include?("darwin") ? "open" : "xdg-open"
      notice("opening #{what}")
      in_background { Subprocess.capture(opener, url) }
    end

    def open_new_session
      cwd = selected_session&.cwd || Dir.pwd
      @modal = NewSessionForm.new(cwd: strip_worktree(cwd), pastel: Pastel.new(enabled: @color))
    end

    # A session's cwd may sit inside a worktree another agent is using; carrying
    # that into a new prompt would spawn the new agent there too, writing over
    # the same files. Fall back to the repo the worktree was cut from.
    def strip_worktree(cwd)
      cwd.to_s.sub(%r{/\.claude/worktrees/[^/]+(?:/.*)?\z}, "")
    end

    # `attach:` hands the terminal over as soon as the session starts. Without
    # it we stay in the inbox and poll, so the new row shows up right away
    # rather than at the next tick.
    def start_session(form, attach:)
      v = form.values
      notice("starting session…")
      in_background do
        id = @client.spawn(**v)
        @queue << [:notice, "started #{id}"]
        @queue << [:form_started, form]
        @queue << [:select, id]
        attach ? @queue << [:attach, id] : @poller.soon
      rescue AgentsClient::Error => e
        @queue << [:form_failed, form, e.message]
      end
    end

    # A spawn failure hands the form back rather than just logging it, so
    # the composed prompt survives (see NewSessionForm#submission_failed).
    def form_failed(form, message)
      @modal.equal?(form) ? form.submission_failed(message) : (@error = message)
    end

    # The new-session form takes the whole body; a Dialog is a box over it.
    def screen_lines(width, height)
      return nil unless @modal.is_a?(NewSessionForm)
      {lines: @modal.screen(width, height - 2), footer: @modal.footer}
    end

    def modal_lines(width)
      @modal.frame(width, @renderer.caret) if @modal.is_a?(Dialog)
    end

    def handle_modal_key(name, key)
      return handle_form_key(name, key) if @modal.is_a?(NewSessionForm)
      case @modal.press(name, key)
      when :cancel then @modal = nil
      when :snooze
        @store.snooze(@modal.id, @modal.choice)
        @modal = nil
      when :confirm
        kind, id = @modal.kind, @modal.id
        @modal = nil
        case kind
        when :stop then stop_session(id)
        when :delete then delete_session(id)
        when :adopt then adopt_session(id)
        end
      when :save then save_prompt
      end
    end

    # `:start`/`:start_and_attach` leave the form as `@modal`, now busy: it
    # closes itself once the spawn is confirmed to have started (`:form_started`)
    # or reopens with the failure and the prompt intact (`:form_failed`).
    def handle_form_key(name, key)
      form = @modal
      case form.press(name, key)
      when :cancel then @modal = nil
      when :start then start_session(form, attach: false)
      when :start_and_attach then start_session(form, attach: true)
      end
    end

    def stop_session(id)
      in_background do
        @client.stop(id)
        @poller.soon
      end
    end

    def adopt_session(key)
      s = session_for(key)
      return unless s&.remote?
      notice("adopting #{s.display_name}…")
      in_background do
        id = @client.adopt(session_id: s.session_id, cwd: s.cwd, pid: s.pid)
        @queue << [:notice, "adopted as #{id}"]
        @queue << [:select, id]
        @queue << [:attach, id]
      end
    end

    def delete_session(id)
      notice("deleting #{id}…")
      in_background do
        @client.rm(id)
        @store.forget(id)
        @queue << [:notice, "deleted #{id}"]
        @poller.soon
      end
    end

    def save_prompt
      value = @modal.value.strip
      if @modal.kind == :alias
        @store.set_alias(@modal.id, value)
      elsif value.empty? || PullRequests.valid_url?(value)
        @store.set_pr(@modal.id, value)
        @poller.soon
      else
        return notice("that's not a github.com pull request url")
      end
      @modal = nil
    end

    # ----- filter line --------------------------------------------------------

    def start_filter
      @filter ||= TextBuffer.new
      @filter_editing = true
    end

    def clear_filter
      @filter = nil
      @filter_editing = false
    end

    def handle_line_key(name, key)
      case name
      when :escape then clear_filter
      when :return, :enter then @filter_editing = false
      when :backspace, :ctrl_h
        @filter.empty? ? clear_filter : @filter.press(name, key)
      else
        @filter.press(name, key)
      end
    end
  end
end
