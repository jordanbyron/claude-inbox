# frozen_string_literal: true

require "fileutils"
require_relative "poller"
require_relative "pull_requests"
require_relative "reaper"
require_relative "snapshot"

module ClaudeInbox
  # The poller and the snapshot with no terminal, for a front end that only
  # reads the file. One per machine, by a lock; a second exits at once. It
  # never reaps: deleting sessions stays with the inbox you can see.
  class Headless
    LOCK_PATH = File.join(Dir.home, ".config", "claude-inbox", "headless.lock")

    def initialize(client:, store:, pull_requests: PullRequests.new, snapshot: Snapshot.new, queue: Queue.new,
      lock_path: LOCK_PATH, clock: -> { Time.now })
      @store = store
      @snapshot = snapshot
      @queue = queue
      @lock_path = lock_path
      @clock = clock
      @poller = Poller.new(client: client, store: store, pull_requests: pull_requests, reaper: Reaper.disabled, queue: queue)
    end

    # False when another headless inbox holds the lock.
    def run
      return false unless take_lock
      @poller.start
      loop { step }
    end

    # Between polls it watches for another front end's edit, as the screen does.
    def step
      kind, *rest = @queue.pop(timeout: 1)
      @store.update(rest[0]) if kind == :sessions
      @store.reload_if_changed if kind.nil?
      @snapshot.write(@store.sections(@clock.call), @clock.call)
    end

    private

    def take_lock
      FileUtils.mkdir_p(File.dirname(@lock_path))
      file = File.open(@lock_path, File::RDWR | File::CREAT, 0o600)
      return false unless file.flock(File::LOCK_EX | File::LOCK_NB)
      file.truncate(0)
      file.write(Process.pid.to_s)
      file.flush
      @lock = file
      true
    end
  end
end
