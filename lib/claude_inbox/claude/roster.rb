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
        status = JSON.parse(File.read(File.join(dir, "#{pid}.json")))["status"]
        status.is_a?(String) ? status : nil
      rescue JSON::ParserError, SystemCallError
        nil
      end
    end
  end
end
