# frozen_string_literal: true

require "json"

module ClaudeInbox
  # The directories whose trust dialog has been accepted, read from where
  # the CLI keeps the answer (see docs/cli-quirks.md). For choosing which
  # directories to offer and in what order, never as a gate: whether a
  # session may start somewhere stays the CLI's call.
  module Trust
    def self.projects(path: File.join(Dir.home, ".claude.json"))
      data = JSON.parse(File.read(path))
      projects = data["projects"] if data.is_a?(Hash)
      return [] unless projects.is_a?(Hash)
      projects.filter_map do |dir, entry|
        dir if dir.start_with?("/") && !dir.include?("\0") &&
          entry.is_a?(Hash) && entry["hasTrustDialogAccepted"] == true
      end
    rescue SystemCallError, IOError, JSON::ParserError
      []
    end
  end
end
