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
  #
  # Every poll runs on one worker thread. The timer is a wait on a wake
  # queue: `soon` drops a token on it and returns, and the worker polls
  # either when a token lands or when the wait times out. A burst of
  # wake-ups before the worker gets to them collapses into one poll. Two
  # polls can never overlap, so the list can't be published out of order
  # and the reaper and the gh refresh never run twice at once. `pause`
  # skips the poll rather than the timer.
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

    # The first poll is a wake-up like any other, so the list is up as soon
    # as the worker starts rather than an interval later.
    def start
      soon
      @thread = Thread.new { worker }
    end

    def stop = @thread&.kill

    # Skips the poll rather than the timer, so nothing forks `claude` while
    # another process holds the terminal. A poll already under way when this
    # is called runs to its end; App pauses before it releases the terminal
    # so that the next one, not the current one, is the one held back.
    def pause = @lock.synchronize { @paused = true }

    # Polls at once as well, so the list catches up the moment an attach
    # returns instead of at the next tick.
    def resume
      @lock.synchronize { @paused = false }
      soon
    end

    def soon = @wake << true

    # PR lookups and the reap sweep both happen here, on the poller, so
    # neither a slow `gh` nor a `claude rm` can stall a frame. Neither is
    # allowed ahead of the list either: the rows go up as soon as `claude
    # agents` answers, and the slow calls follow. A dozen serial `gh pr
    # view`s, or a couple of `claude rm`s clearing worktrees, is the
    # difference between the inbox appearing at once and five seconds later.
    #
    # Reaped rows are dropped before the queue and not after: `update` folds
    # whatever it is handed back into the entry table, so a session still in
    # this list would be recreated moments after `forget` cleared it and
    # flicker back for a poll. So the reaper says what it is about to take
    # (a pure lookup) and those rows are held back from the first hand-over;
    # only a refused reap brings one back. The gh refresh comes last and
    # publishes again only if a PR state moved.
    def once
      now = Time.now
      sessions = Sessions.load(client: @client, jobs_dir: @jobs_dir, pull_requests: @pull_requests, overrides: @store.pr_overrides)
      doomed = @reaper.due(sessions, now)
      publish(sessions, doomed)
      reaped = @reaper.sweep(sessions, now)
      live = publish(sessions, reaped) if reaped != doomed
      live ||= sessions.reject { |s| doomed.include?(s.key) }
      notice_reaped(reaped) if reaped.any?
      fresh, moved = @pull_requests.refresh(live)
      @queue << [:sessions, fresh] if moved
    rescue => e
      @queue << [:error, e.message]
    end

    private

    def worker
      loop do
        @wake.pop(timeout: @interval)
        @wake.clear
        once unless paused?
      end
    end

    def paused? = @lock.synchronize { @paused }

    # Hands the sessions minus `without` to the main thread; returns the
    # list it kept.
    def publish(sessions, without)
      live = sessions.reject { |s| without.include?(s.key) }
      @queue << [:sessions, live]
      live
    end

    def notice_reaped(keys)
      word = (keys.size == 1) ? "session" : "sessions"
      @queue << [:notice, "reaped #{keys.size} #{word} idle over #{Store::REAP_AFTER / 86_400}d — see #{@reaper.log_path}"]
    end
  end
end
