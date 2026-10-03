# frozen_string_literal: true

require "fileutils"
require_relative "records"

module ClaudeInbox
  # What another front end asks the inbox to do to a session: one file per
  # request under a directory, taken and applied here, so the triage rules
  # and the state file have one owner. A request the store cannot honour, an
  # unknown session or verb, is dropped with the file.
  class Actions
    DEFAULT_DIR = File.join(Dir.home, ".config", "claude-inbox", "actions")
    VERBS = %w[settle wake pin snooze].freeze
    SNOOZES = %w[m15 h1 tomorrow_9am until_woken].freeze

    def self.disabled = new(dir: nil)

    def initialize(dir: DEFAULT_DIR)
      @dir = dir
    end

    # Applies every request on disk to `store` and returns how many it took.
    def drain(store)
      return 0 unless @dir && File.directory?(@dir)
      keys = store.sessions.select(&:actionable?).map(&:key)
      Dir.glob(File.join(@dir, "*.json")).sort.count do |path|
        request = Records.read(path)
        # A file still being written parses as nothing; it waits for the next pass.
        next false if request.empty?
        File.delete(path)
        apply(store, request, keys)
      end
    end

    private

    def apply(store, request, keys)
      id = request["id"]
      return false unless keys.include?(id) && VERBS.include?(request["action"])
      case request["action"]
      when "settle" then store.settle(id)
      when "wake" then store.wake(id)
      when "pin" then store.toggle_pin(id)
      when "snooze"
        return false unless SNOOZES.include?(request["choice"])
        store.snooze(id, request["choice"].to_sym)
      end
      true
    rescue Errno::ENOENT
      false
    end
  end
end
