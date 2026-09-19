# frozen_string_literal: true

require_relative "vt_screen"

module ClaudeInbox
  # The `claude logs <id>` replay of each session as readable lines, fetched
  # off the main thread, debounced and cached.
  class Logs
    DEBOUNCE = 0.25
    TTL = 10
    MAX_LINES = 400

    def initialize(client, clock: -> { Time.now })
      @client = client
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

    def want(id)
      return if id.nil?
      @pending = id
      @pending_at = @clock.call
    end

    # Promotes a request that has sat still for DEBOUNCE to the worker,
    # unless the cache already has a fresh answer.
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
