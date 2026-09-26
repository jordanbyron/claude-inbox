# frozen_string_literal: true

require "shellwords"

module ClaudeInbox
  # Arguments for every launch. They go before the typed ones, so a typed
  # flag wins.
  module Config
    PATH = File.join(Dir.home, ".config", "claude-inbox", "config")

    def self.argv(typed, path: PATH)
      args(path) + typed
    end

    def self.args(path)
      File.readlines(path).flat_map { |line| Shellwords.split(line.sub(/(\A|\s)#.*/, "")) }
    rescue Errno::ENOENT
      []
    rescue ArgumentError => e
      raise ArgumentError, "#{path}: #{e.message}"
    end
    private_class_method :args
  end
end
