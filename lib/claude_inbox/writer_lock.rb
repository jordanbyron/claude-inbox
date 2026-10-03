# frozen_string_literal: true

require "fileutils"

module ClaudeInbox
  # One snapshot writer per machine: the inbox you can see, else a headless
  # one. The inbox takes the lock over from a headless process, which it ends;
  # a headless process that finds the lock held exits instead.
  class WriterLock
    DEFAULT_PATH = File.join(Dir.home, ".config", "claude-inbox", "writer.lock")
    EVICT_TRIES = 20

    def self.disabled = new(path: nil)

    def initialize(path: DEFAULT_PATH)
      @path = path
      @file = nil
    end

    # True once held. With `evict`, the holder is sent TERM and the lock
    # waited for; without, a held lock is simply refused.
    def take(evict: false)
      return true unless @path
      FileUtils.mkdir_p(File.dirname(@path))
      file = File.open(@path, File::RDWR | File::CREAT, 0o600)
      return hold(file) if file.flock(File::LOCK_EX | File::LOCK_NB)
      return refuse(file) unless evict
      holder = file.read.to_i
      Process.kill("TERM", holder) if holder.positive? && holder != Process.pid
      EVICT_TRIES.times do
        return hold(file) if file.flock(File::LOCK_EX | File::LOCK_NB)
        sleep 0.1
      end
      refuse(file)
    rescue Errno::ESRCH, Errno::EPERM
      retry_take(file)
    end

    def held? = !@file.nil?

    def release
      @file&.close
      @file = nil
    end

    private

    def hold(file)
      file.truncate(0)
      file.write(Process.pid.to_s)
      file.flush
      @file = file
      true
    end

    def refuse(file)
      file.close
      false
    end

    # The holder recorded in the file is gone already: the lock is free.
    def retry_take(file)
      hold(file) if file.flock(File::LOCK_EX | File::LOCK_NB)
      held? || refuse(file)
    end
  end
end
