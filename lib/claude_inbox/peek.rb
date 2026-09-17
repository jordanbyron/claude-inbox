# frozen_string_literal: true

require_relative "vt_screen"

module ClaudeInbox
  # Fetches `claude logs <id>` off the main thread, debounced and cached.
  # Requests come in via #want(id); results go out on the shared queue as
  # [:peek, id, lines].
  class Peek
    DEBOUNCE = 0.25
    TTL = 10
    MAX_LINES = 400

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
    end

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
