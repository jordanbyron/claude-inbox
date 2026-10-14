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
require_relative "remote/listener"
require_relative "mouse"
require_relative "new_session_form"
require_relative "paste"
require_relative "pull_requests"
require_relative "reaper"
require_relative "poller"
require_relative "rate_limits"
require_relative "session_request"
require_relative "actions"
require_relative "snapshot"
require_relative "switch"
require_relative "trust"
require_relative "mod"
require_relative "updater"
require_relative "app/updating"
require_relative "app/filtering"
require_relative "app/triaging"
require_relative "app/navigating"
require_relative "app/attaching"

module ClaudeInbox
  # Owns the terminal and the key loop. The only class allowed to spawn a
  # child process that takes over the terminal.
  class App
    include Updating
    include Filtering
    include Triaging
    include Navigating
    include Attaching

    # The reaper deletes sessions and the listener lets other machines in,
    # so both are off unless `bin/claude-inbox` switches them on.
    def initialize(client: AgentsClient.new, store: Store.new, pull_requests: PullRequests.new,
      rate_limits: RateLimits.new, reaper: Reaper.disabled, snapshot: Snapshot.disabled, switch: Switch.disabled,
      actions: Actions.disabled, listen: nil, updater: nil, argv: [], out: $stdout, input: $stdin, color: true,
      trust: Trust.method(:projects), terminal: Terminal.new(out, input), queue: Queue.new, pane_offer: Mod::Offer.disabled)
      @client = client
      @store = store
      @snapshot = snapshot
      @switch = switch
      @rate_limits = rate_limits
      @terminal = terminal
      @updater = updater
      @argv = argv
      @out = out
      @color = color
      @trust = trust
      @renderer = Renderer.new(color: color)
      @input = input
      @reader = TTY::Reader.new(input: input, output: out, interrupt: :noop)
      @queue = queue
      @poller = Poller.new(client: client, store: store, pull_requests: pull_requests,
        reaper: reaper, queue: @queue, snapshot: snapshot, actions: actions)
      @listener = listen ? Remote::Listener.new(client: client, store: store, queue: @queue, **listen) : Remote::Listener.disabled
      @logs = Logs.new(client)
      @peek = Peek.new(@logs)
      @keymap = Keymap.new
      @paste = Paste.new
      @tick = 0
      @modal = nil
      @last_poll = nil
      @quit = false
      @resize = false
      @pane_offer = pane_offer
      @modal = Dialog::PaneOffer.new if pane_offer.take
    end

    def run
      @booted_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      install_traps
      @terminal.enter
      @poller.start
      @listener.start
      @logs.start
      main_loop
    ensure
      @poller.stop
      @logs.stop
      @terminal.restore
      @listener.stop
    end

    def step(input = nil)
      ensure_update_checked
      drain_queue
      @logs.tick
      if @resize
        @resize = false
        @terminal.resized
      end
      handle_input(input) if input
      # A paste arrives a character per read and shows nothing until it
      # closes, so a frame per character would only stall a long one.
      render unless @paste.pasting?
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
          @last_poll = Time.now
          @error = nil
        when :error then @error = rest[0]
        when :notice then notice(rest[0])
        when :update then update_checked(*rest)
        when :select then select_later(rest[0])
        when :attach then attach(rest[0])
        when :form_started then @modal = nil if @modal.equal?(rest[0])
        when :form_failed then form_failed(*rest)
        when :remote_started then remote_started(*rest)
        end
      end
    end

    # ----- main loop --------------------------------------------------------

    def main_loop
      step(@paste.pasting? ? read_pasted : @reader.read_keypress(echo: false, raw: false, nonblock: true)) until @quit
    end

    # As much of an open paste as has arrived, read straight off the tty:
    # the reader switches echo off and back on around every character, and
    # on a long paste that is most of the wait.
    def read_pasted
      return nil unless @input.wait_readable(0.1)
      out = +""
      while out.size < 65_536 && @input.wait_readable(0) && (c = @input.getc)
        out << c
      end
      out
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
    # take it as typing, so a pasted PR URL lands where it should. Anywhere
    # else a paste is dropped: typed out, its letters would be keys, and a
    # "y" answers a confirm.
    def handle_paste(text)
      return @modal.paste(text) if @modal.is_a?(NewSessionForm)
      typing = @modal ? @modal.is_a?(Dialog::Prompt) : filter_editing?
      text.each_char { |c| handle_key(c) } if typing
    end

    def render
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      now = Time.now
      all = @store.sections(now)
      @snapshot.write(all, now)
      sections = filtered(all)
      width, height = @terminal.size
      body_h = Renderer.body_height(height)
      ensure_selection(sections)
      @tick += 1
      view = Renderer::View.new(
        width: width, height: height, now: now, selected: @selected&.key, top: top, expanded: expanded,
        peek: @peek.view(sections.row(@selected), body_h), modal: modal_lines(width), screen: screen_lines(width, body_h),
        status: status_text(now), usage: @rate_limits.windows(now), filter: filter, filter_editing: filter_editing?,
        tick: @tick / 2, loading: loading_for, listening: @listener.snapshot
      )
      frame = @renderer.frame(sections, view)
      placed(frame)
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
      return "polling…" unless @last_poll
      update_notice
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
      return handle_line_key(name, key) if filter_editing?

      action = @keymap.press(name, key)
      perform(action) if action
    end

    # A modal or an open filter line already claims every keypress ahead of
    # the normal action table (see handle_key); mouse input defers to the
    # same rule rather than reaching past whatever has focus.
    def handle_mouse(event)
      return if @modal || filter_editing?
      case event.kind
      when :click then click_row(event.row, event.col)
      when :scroll_up then perform(:up)
      when :scroll_down then perform(:down)
      end
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
      when :fold_toggle then toggle_expanded
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
      when :update then update_inbox
      when :toggle_peek then toggle_peek
      when :new_session then open_new_session
      when :remote_pairing then @modal = @listener.pairing_dialog
      when :filter then start_filter
      when :escape then clear_filter
      end
    end

    # vim-ish "h": close whatever is open, innermost first.
    def collapse
      if @peek.open? then @peek.close
      else set_expanded(false)
      end
      @terminal.invalidate
    end

    def toggle_peek
      @peek.toggle
      @terminal.invalidate
    end

    # ----- modals -----------------------------------------------------------

    def open_confirm(kind)
      return unless require_actionable
      @modal = Dialog::Confirm.new(kind, @selected.key)
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
      dirs = SessionRequest.directories(@store.sessions, @trust.call)
      @modal = NewSessionForm.new(cwd: SessionRequest.strip_worktree(cwd), color: @color, dirs: dirs)
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

    # Someone at the desk may be mid-thought, so a start from another
    # device never moves the cursor, attaches or closes what is open.
    def remote_started(id, via)
      notice("started #{id} from #{via}")
      @poller.soon
    end

    # A spawn failure hands the form back rather than just logging it, so
    # the composed prompt survives (see NewSessionForm#submission_failed).
    def form_failed(form, message)
      @modal.equal?(form) ? form.submission_failed(message) : (@error = message)
    end

    # The new-session form takes the whole body; a Dialog is a box over it.
    def screen_lines(width, body_h)
      return nil unless @modal.is_a?(NewSessionForm)
      {lines: @modal.screen(width, body_h), footer: @modal.footer}
    end

    def modal_lines(width)
      @modal.frame(width, @renderer.caret) if @modal.is_a?(Dialog)
    end

    def handle_modal_key(name, key)
      return handle_form_key(name, key) if @modal.is_a?(NewSessionForm)
      case @modal.press(name, key)
      when :cancel then @modal = nil
      when :snooze then snooze_chosen
      when :confirm
        kind, id = @modal.kind, @modal.id
        @modal = nil
        case kind
        when :stop then stop_session(id)
        when :delete then delete_session(id)
        when :adopt then adopt_session(id)
        when :install then install_pane
        end
      when :save then save_prompt
      when :copy then @listener.copy_pairing_url
      when :rotate then @listener.rotate
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

    def install_pane
      @pane_offer.install
      notice("added the pane — new Claude Code sessions load it; /inbox opens it")
    rescue JSON::ParserError
      notice("~/.claude/settings.json is not valid JSON, so it was left alone")
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
  end
end
