# frozen_string_literal: true

require_relative "agents_client"
require_relative "debug"
require_relative "dialog"
require_relative "input"
require_relative "text_buffer"
require_relative "store"
require_relative "renderer"
require_relative "terminal"
require_relative "logs"
require_relative "peek"
require_relative "keymap"
require_relative "remote/listener"
require_relative "new_session_form"
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
require_relative "app/spawning"
require_relative "app/browsing"

module ClaudeInbox
  # Owns the terminal and the key loop. The only class allowed to spawn a
  # child process that takes over the terminal.
  class App
    include Updating
    include Filtering
    include Triaging
    include Navigating
    include Attaching
    include Spawning
    include Browsing

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
      @input = Input.new(input, out)
      @queue = queue
      @poller = Poller.new(client: client, store: store, pull_requests: pull_requests,
        reaper: reaper, queue: @queue, snapshot: snapshot, actions: actions)
      @listener = listen ? Remote::Listener.new(client: client, store: store, queue: @queue, **listen) : Remote::Listener.disabled
      @logs = Logs.new(client)
      @peek = Peek.new(@logs)
      @selected = nil
      @row_items = []
      @list_width = nil
      @top = 0
      @expanded = Hash.new(false)
      @keymap = Keymap.new
      @tick = 0
      @modal = nil
      @filter = nil
      @filter_editing = false
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
      render unless @input.pasting?
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
        when :form_started then form_started(rest[0])
        when :form_failed then form_failed(*rest)
        when :remote_started then remote_started(*rest)
        end
      end
    end

    # ----- main loop --------------------------------------------------------

    def main_loop
      step(@input.read) until @quit
    end

    def handle_input(raw)
      @input.events(raw).each do |kind, *event|
        case kind
        when :paste then handle_paste(*event)
        when :mouse then handle_mouse(*event)
        when :key then handle_key(*event)
        end
      end
    end

    # The form takes a paste whole, images included; the one-line editors
    # take it as typing, so a pasted PR URL lands where it should. Anywhere
    # else a paste is dropped: typed out, its letters would be keys, and a
    # "y" answers a confirm.
    def handle_paste(text)
      return @modal.paste(text) if @modal.is_a?(NewSessionForm)
      typing = @modal ? @modal.is_a?(Dialog::Prompt) : filter_editing?
      @input.typed(text).each { |name, c| handle_key(name, c) } if typing
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
        width: width, height: height, now: now, selected: @selected&.key, top: @top, expanded: @expanded,
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

    def handle_key(name, key)
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

    def install_pane
      @pane_offer.install
      notice("added the pane — new Claude Code sessions load it; /inbox opens it")
    rescue JSON::ParserError
      notice("~/.claude/settings.json is not valid JSON, so it was left alone")
    end
  end
end
