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
      projects.filter_map { |dir, entry| dir if entry.is_a?(Hash) && entry["hasTrustDialogAccepted"] == true }
    rescue SystemCallError, IOError, JSON::ParserError
      []
    end

    # Whether `dir` is one of `projects` or sits under one, by realpath, so
    # a symlinked checkout matches. Looser than the CLI, which stops looking
    # at a git repository's root; close enough for ordering.
    def self.covers?(dir, projects)
      return false unless (real = realpath(dir))
      projects.filter_map { |project| realpath(project) }
        .any? { |root| real == root || real.start_with?(File.join(root, "")) }
    end

    def self.realpath(path)
      File.realpath(path)
    rescue SystemCallError
      nil
    end
    private_class_method :realpath
  end
end
