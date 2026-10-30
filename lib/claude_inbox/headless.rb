# frozen_string_literal: true

require_relative "actions"
require_relative "notifier"
require_relative "poller"
require_relative "pull_requests"
require_relative "reaper"
require_relative "snapshot"

require_relative "updater"
require_relative "writer_lock"

module ClaudeInbox
  # The poller with no terminal, for a front end that only reads the
  # snapshot: it polls, writes the file and applies the requests. It never
  # reaps, since deleting sessions stays with the inbox you can see, and it
  # exits at once while an inbox holds the writer lock.
  class Headless
    RECHECK_EVERY = 60

    def initialize(client:, store:, pull_requests: PullRequests.new, actions: Actions.new, snapshot: Snapshot.new,
      lock: WriterLock.new, updater: nil, notifier: Notifier.disabled, recheck_every: RECHECK_EVERY)
      @lock = lock
      @snapshot = snapshot
      @updater = updater
      @recheck_every = recheck_every
      @notice = nil
      @queue = Queue.new
      @poller = Poller.new(client: client, store: store, pull_requests: pull_requests, reaper: Reaper.disabled,
        queue: @queue, snapshot: snapshot, actions: actions, notifier: notifier)
    end

    # False when the lock is held, by an inbox or another headless process.
    def run
      return false unless @lock.take(role: "headless")
      @poller.start
      updates = Thread.new { watch_for_updates } if @updater
      loop { @queue.pop }
    ensure
      @poller.stop
      updates&.kill
    end

    private

    # After the poller is off, since the check may wait on the network. The
    # pane cannot swap the process under Claude Code, so the snapshot only
    # says a newer one is out, and a check that cannot tell says nothing.
    # Re-checked because this process outlives an update applied from a
    # terminal; the updater's day-long cache keeps that off the network.
    def watch_for_updates
      loop do
        check_for_update
        sleep @recheck_every
      end
    end

    def check_for_update
      notice = @updater.check&.notice
      return if notice == @notice
      @notice = @snapshot.update = notice
      @poller.soon
    rescue Updater::Error
      nil
    end
  end
end
