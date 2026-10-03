# frozen_string_literal: true

require_relative "actions"
require_relative "sessions"
require_relative "snapshot"

module ClaudeInbox
  # Asks `claude agents` for the list off the main thread, every INTERVAL
  # seconds and on demand, puts what it finds in the store and the snapshot,
  # and tells App over the shared queue: [:sessions, list] for each
  # hand-over, [:error, msg] when a poll fails, [:notice, text] when the
  # reaper took something. Between polls it applies what another front end
  # asked for. Nothing here touches App's state directly; the queue is the
  # whole of the interface. One worker runs every poll, so two can never
  # overlap and publish the list out of order.
  class Poller
    INTERVAL = 4
    ACTIONS_INTERVAL = 0.5

    def initialize(client:, store:, pull_requests:, reaper:, queue:, snapshot: Snapshot.disabled, actions: Actions.disabled,
      interval: INTERVAL, clock: -> { Time.now })
      @client = client
      @clock = clock
      @store = store
      @pull_requests = pull_requests
      @reaper = reaper
      @queue = queue
      @snapshot = snapshot
      @actions = actions
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
    # dropped it. The gh refresh comes last and publishes again only if a PR
    # state moved.
    def once
      now = @clock.call
      sessions = Sessions.load(client: @client, pull_requests: @pull_requests, overrides: @store.pr_overrides)
      doomed = @reaper.due(sessions, now)
      @store.hide(doomed)
      publish(sessions)
      reaped = []
      begin
        reaped = @reaper.sweep(sessions.select { |s| doomed.include?(s.key) }, now)
      ensure
        @store.release(doomed - reaped)
      end
      publish(sessions) if reaped != doomed
      @queue << [:notice, @reaper.report(reaped)] if reaped.any?
      fresh, moved = @pull_requests.refresh(sessions)
      publish(fresh) if moved
    rescue => e
      @queue << [:error, e.message]
    end

    # Applies the requests another front end left, and says whether any landed.
    def apply
      return false unless @actions.drain(@store) > 0
      write_snapshot
      true
    end

    private

    def publish(sessions)
      @store.update(sessions)
      write_snapshot
      @queue << [:sessions, sessions]
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
