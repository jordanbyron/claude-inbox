# frozen_string_literal: true

require_relative "actions"
require_relative "poller"
require_relative "pull_requests"
require_relative "reaper"
require_relative "snapshot"
require_relative "writer_lock"

module ClaudeInbox
  # The poller with no terminal, for a front end that only reads the
  # snapshot: it polls, writes the file and applies the requests. It never
  # reaps, since deleting sessions stays with the inbox you can see, and it
  # exits at once while an inbox holds the writer lock.
  class Headless
    def initialize(client:, store:, pull_requests: PullRequests.new, snapshot: Snapshot.new, actions: Actions.new,
      lock: WriterLock.new, queue: Queue.new)
      @lock = lock
      @queue = queue
      @poller = Poller.new(client: client, store: store, pull_requests: pull_requests, reaper: Reaper.disabled,
        queue: queue, snapshot: snapshot, actions: actions)
    end

    # False when the lock is held, by an inbox or another headless process.
    def run
      return false unless @lock.take(role: "headless")
      @poller.start
      loop { @queue.pop }
    end
  end
end
