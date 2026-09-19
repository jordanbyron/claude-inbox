# frozen_string_literal: true

require_relative "reaper"
require_relative "sessions"
require_relative "store"

module ClaudeInbox
  # Asks `claude agents` for the list off the main thread, every INTERVAL
  # seconds and on demand, and hands what it finds to App over the shared
  # queue: [:sessions, list] for each hand-over, [:error, msg] when a poll
  # fails, [:notice, text] when the reaper took something. Nothing here
  # touches App's state directly; the queue is the whole of the interface.
  # One worker runs every poll, so two can never overlap and publish the
  # list out of order.
  class Poller
    INTERVAL = 4

    def initialize(client:, store:, pull_requests:, jobs_dir:, reaper:, queue:, interval: INTERVAL)
      @client = client
      @store = store
      @pull_requests = pull_requests
      @jobs_dir = jobs_dir
      @reaper = reaper
      @queue = queue
      @interval = interval
      @wake = Queue.new
      @paused = false
      @lock = Mutex.new
    end

    def start
      return if @thread&.alive?
      soon
      @thread = Thread.new { worker }
    end

    def stop = @thread&.kill

    # Skips the poll rather than the timer, so nothing forks `claude` while
    # another process holds the terminal. A poll already under way finishes.
    def pause = @lock.synchronize { @paused = true }

    def resume
      @lock.synchronize { @paused = false }
      soon
    end

    def soon = @wake << true

    # The rows go up as soon as `claude agents` answers, and the slow calls
    # (`claude rm`, a dozen serial `gh pr view`s) follow: that is the
    # difference between the inbox appearing at once and five seconds later.
    # Every hand-over is the whole list; the store hides the rows the reaper
    # is about to take, so a list missing a key can only mean the daemon
    # dropped it. The gh refresh comes last and publishes again only if a PR
    # state moved.
    def once
      now = Time.now
      sessions = Sessions.load(client: @client, jobs_dir: @jobs_dir, pull_requests: @pull_requests, overrides: @store.pr_overrides)
      doomed = @reaper.due(sessions, now)
      @store.hide(doomed)
      @queue << [:sessions, sessions]
      reaped = []
      begin
        reaped = @reaper.sweep(sessions.select { |s| doomed.include?(s.key) }, now)
      ensure
        @store.release(doomed - reaped)
      end
      @queue << [:sessions, sessions] if reaped != doomed
      notice_reaped(reaped) if reaped.any?
      fresh, moved = @pull_requests.refresh(sessions)
      @queue << [:sessions, fresh] if moved
    rescue => e
      @queue << [:error, e.message]
    end

    private

    # Past StandardError `once` does not catch, and a dead worker would end
    # polling with nothing on screen to say so.
    def worker
      loop do
        @wake.pop(timeout: @interval)
        @wake.clear
        once unless paused?
      rescue SystemStackError, ScriptError, SecurityError => e
        @queue << [:error, e.message]
      end
    end

    def paused? = @lock.synchronize { @paused }

    def notice_reaped(keys)
      word = (keys.size == 1) ? "session" : "sessions"
      @queue << [:notice, "reaped #{keys.size} #{word} idle over #{Store::REAP_AFTER / 86_400}d — see #{@reaper.log_path}"]
    end
  end
end
