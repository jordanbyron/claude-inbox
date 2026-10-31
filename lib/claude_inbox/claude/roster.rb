# frozen_string_literal: true

require "json"

module ClaudeInbox
  module Claude
    # What a session's own process says it is doing, from ~/.claude/sessions/<pid>.json.
    # `claude agents --json` reads the same file but reports `shell` as `busy` (docs/cli-quirks.md).
    class Roster
      DEFAULT_DIR = File.join(Dir.home, ".claude", "sessions")

      # => "busy", "shell", "waiting" or "idle"; nil without a readable file for this pid.
      def self.status(pid, dir: DEFAULT_DIR)
        return nil unless pid
        status = record(File.join(dir, "#{pid}.json"))["status"]
        status.is_a?(String) ? status : nil
      end

      # => a value that changes when any session's status does, or a session
      # starts or ends: each file's pid, status and when the status was set.
      def self.pulse(dir: DEFAULT_DIR)
        Dir.glob(File.join(dir, "*.json")).sort.map { |path| record(path).values_at("pid", "status", "statusUpdatedAt") }
      end

      def self.record(path)
        parsed = JSON.parse(File.read(path))
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError, SystemCallError
        {}
      end
      private_class_method :record
    end
  end
end
