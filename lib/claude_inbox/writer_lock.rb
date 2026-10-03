# frozen_string_literal: true

require "fileutils"

module ClaudeInbox
  # One snapshot writer per machine: the inbox you can see, else a headless
  # one. The file names the holder's role beside its pid, so an inbox takes
  # the lock over from a headless process, which it ends, and never from
  # another inbox; a headless process that finds the lock held exits.
  class WriterLock
    DEFAULT_PATH = File.join(Dir.home, ".config", "claude-inbox", "writer.lock")
    EVICT_TRIES = 20

    def self.disabled = new(path: nil)

    def initialize(path: DEFAULT_PATH)
      @path = path
      @file = nil
    end

    # True once held. Only a headless holder is evicted, and only by an inbox.
    def take(role:)
      return true unless @path
      FileUtils.mkdir_p(File.dirname(@path))
      file = File.open(@path, File::RDWR | File::CREAT, 0o600)
      return hold(file, role) if file.flock(File::LOCK_EX | File::LOCK_NB)
      holder_role, holder = file.read.split
      return refuse(file) unless role == "inbox" && holder_role == "headless"
      Process.kill("TERM", holder.to_i) if holder.to_i.positive? && holder.to_i != Process.pid
      EVICT_TRIES.times do
        return hold(file, role) if file.flock(File::LOCK_EX | File::LOCK_NB)
        sleep 0.1
      end
      refuse(file)
    rescue Errno::ESRCH, Errno::EPERM
      # The holder the file names is gone already: the lock is free.
      file.flock(File::LOCK_EX | File::LOCK_NB) ? hold(file, role) : refuse(file)
    end

    def held? = !@file.nil?

    def release
      @file&.close
      @file = nil
    end

    private

    def hold(file, role)
      file.truncate(0)
      file.write("#{role} #{Process.pid}")
      file.flush
      @file = file
      true
    end

    def refuse(file)
      file.close
      false
    end
  end
end
