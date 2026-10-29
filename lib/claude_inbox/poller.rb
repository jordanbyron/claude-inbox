# frozen_string_literal: true

require_relative "notifier"

module ClaudeInbox
  # Asks the client for the list off the main thread, every INTERVAL
  # seconds and on demand, puts what it finds in the store and the snapshot,
  # and tells App over the shared queue. Between polls it applies what
  # another front end asked for. Nothing here touches App's state directly;
  # the queue is the whole of the interface. One worker runs every poll, so
  # two can never overlap and publish the list out of order.
  class Poller
    INTERVAL = 4
    ACTIONS_INTERVAL = 0.5

    def initialize(client:, store:, pull_requests:, reaper:, queue:, snapshot:, actions:,
      notifier: Notifier.disabled, interval: INTERVAL, clock: -> { Time.now })
      @client = client
      @clock = clock
      @store = store
      @pull_requests = pull_requests

      @reaper = reaper
      @queue = queue
      @snapshot = snapshot
      @actions = actions
      @notifier = notifier
      @interval = interval
      @wake = Queue.new
    end

    def start
      return if @thread&.alive?
      soon
      @thread = Thread.new { worker }
      @applier = Thread.new { applier }
    end

    def stop
      @thread&.kill
      @applier&.kill
    end

    def soon = @wake << true

    # The rows go up as soon as `claude agents` answers, and the slow calls
    # (`claude rm`, a dozen serial `gh pr view`s) follow: that is the
    # difference between the inbox appearing at once and five seconds later.
    # Every hand-over is the whole list; the store hides the rows the reaper
    # is about to take, so a list missing a key can only mean the daemon
    # dropped it.
    def once
      now = @clock.call
      sessions = @pull_requests.enrich(@client.list, @store.pr_overrides)
      doomed = @reaper.due(sessions, now)
      @store.hide(doomed)
      publish(sessions, now)
      reaped = []
      begin
        reaped = @reaper.sweep(sessions.select { |s| doomed.include?(s.key) }, now)
      ensure
        @store.release(doomed - reaped)
      end
      publish(sessions, now) if reaped != doomed
      @queue << [:notice, @reaper.report(reaped)] if reaped.any?
      fresh, moved = @pull_requests.refresh(sessions)
      publish(fresh, now) if moved
    rescue => e
      @queue << [:error, e.message]
    end

    def apply
      write_snapshot if @actions.drain(@store) > 0
    end

    private

    # The notifier compares the sections from just before the hand-over, so
    # a row you woke or unpinned yourself since the last poll says nothing.
    def publish(sessions, fetched_at)
      now = @clock.call
      before = @store.sections(now)
      @store.update(sessions, fetched_at:)
      after = @store.sections(now)
      @snapshot.write(after, now)
      @notifier.deliver(before, after) { |msg| @queue << [:notice, msg] }
      @queue << [:sessions]
    end

    def write_snapshot
      now = @clock.call
      @snapshot.write(@store.sections(now), now)
    end

    # Past StandardError `once` does not catch, and a dead worker would end
    # polling with nothing on screen to say so.
    def worker
      loop do
        @wake.pop(timeout: @interval)
        @wake.clear
        once
      rescue SystemStackError, ScriptError, SecurityError => e
        @queue << [:error, e.message]
      end
    end

    def applier
      loop do
        sleep ACTIONS_INTERVAL
        apply
      rescue => e
        @queue << [:error, e.message]
      end
    end
  end
end
