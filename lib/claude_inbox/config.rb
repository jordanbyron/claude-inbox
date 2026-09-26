# frozen_string_literal: true

require "shellwords"

module ClaudeInbox
  # Launch arguments the user wants every time, read from
  # ~/.config/claude-inbox/config. They go before the typed ones, so a flag
  # on the command line still wins.
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
