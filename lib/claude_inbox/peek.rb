# frozen_string_literal: true

require_relative "vt_screen"

module ClaudeInbox
  # The peek pane: what it shows for the selected row, how far back it is
  # scrolled, and the `claude logs <id>` fetch that feeds it. The fetch runs
  # off the main thread, debounced and cached; requests come in via #want(id)
  # and results go out on the shared queue as [:peek, id, lines]. Everything
  # else is main-thread state and never takes the cache's mutex.
  class Peek
    DEBOUNCE = 0.25
    TTL = 10
    MAX_LINES = 400

    TERMINAL_NOTE = "This is a claude you opened in a terminal yourself. The daemon can't attach to it, read its output, or stop it from outside. Switch to that window."
    REMOTE_NOTE = "This is a Remote Control session driven from claude.ai/code. The daemon can't attach to it or read its output from here. Open it in the web or mobile app instead."

    # What Renderer paints: the body lines, the title bar, the dim line under it.
    View = Struct.new(:lines, :title, :subtitle)

    def initialize(client, queue, clock: -> { Time.now })
      @client = client
      @queue = queue
      @clock = clock
      @cache = {}
      @mutex = Mutex.new
      @pending = nil
      @pending_at = nil
      @requests = Queue.new
      @thread = Thread.new { worker }
      @thread.abort_on_exception = false
      @open = false
      @offset = 0
      @selected = nil
      @session = nil
    end

    # ----- pane -------------------------------------------------------------

    def open? = @open

    def toggle
      @open = !@open
      want(@session.id) if @open && @session&.actionable?
    end

    def close = @open = false

    # Called on every selection change. The logs are asked for even while the
    # pane is closed, so opening it lands on a warm cache. `session` is the
    # selected session when the key names one; a fold has none.
    def select(key, session)
      @selected = key
      @session = session
      @offset = 0
      want(session.id) if session&.actionable?
    end

    # Positive scrolls back into history, negative towards the tail.
    def scroll(delta)
      @offset = [@offset + delta, 0].max
    end

    # `row` is the selected row as the frame shows it, or nil when nothing is
    # selected. Answers nil when there is no pane to paint.
    def view(row, height)
      return nil unless @open && @selected.is_a?(String)
      View.new(scrolled(body(row), height - 2), row&.label || @selected, subtitle(row))
    end

    # ----- fetch ------------------------------------------------------------

    def cached(id)
      @mutex.synchronize { @cache[id]&.first }
    end

    # Called on every selection change from the main thread.
    def want(id)
      return if id.nil?
      @pending = id
      @pending_at = @clock.call
    end

    # Called once per main-loop tick; promotes a debounced request to the worker.
    def tick
      return unless @pending && @clock.call - @pending_at >= DEBOUNCE
      id = @pending
      @pending = nil
      fresh = @mutex.synchronize { (e = @cache[id]) && @clock.call - e[1] < TTL }
      @requests << id unless fresh
    end

    def stop = @thread.kill

    private

    def body(row)
      return ["(nothing selected)"] unless row
      return interactive_note(row.session) if row.session.interactive?
      cached(row.session.id) || ["(loading…)"]
    end

    def interactive_note(s)
      [s.remote? ? REMOTE_NOTE : TERMINAL_NOTE, "", "pid #{s.pid} · #{s.cwd}", "session #{s.session_id}"]
    end

    def subtitle(row)
      return nil unless row
      s = row.session
      parts = [s.effective_state, s.status, s.waiting_for, s.id, s.started_at&.strftime("started %b %-d %H:%M")].compact
      parts += s.prs.map { |pr| "#{pr.short} #{pr.state&.downcase || "?"}" }
      parts.join(" · ")
    end

    # Lines are shown tail-first; the offset scrolls back into history and is
    # clamped to however much history there is.
    def scrolled(lines, view_h)
      return lines if @offset.zero?
      max_off = [lines.size - view_h, 0].max
      @offset = [@offset, max_off].min
      lines[0, lines.size - @offset]
    end

    def worker
      loop do
        id = @requests.pop
        id = @requests.pop until @requests.empty? # only the latest matters
        lines = fetch(id)
        @mutex.synchronize { @cache[id] = [lines, @clock.call] }
        @queue << [:peek, id, lines]
      end
    end

    def fetch(id)
      raw = @client.logs(id)
      return ["(no output available — the session's process is not running)"] if raw.nil?
      VtScreen.new.feed(raw).lines.last(MAX_LINES)
    rescue => e
      ["(logs failed: #{e.message})"]
    end
  end
end
