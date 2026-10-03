# frozen_string_literal: true

require_relative "records"

module ClaudeInbox
  # A request from another front end to attach to a different session: one
  # file, written by the asker and taken by the inbox attached to the asker's
  # own session. Only that inbox can act on it, which is why the asker gives
  # up on a request nobody takes, and why the request names who asked.
  class Switch
    DEFAULT_PATH = File.join(Dir.home, ".config", "claude-inbox", "switch.json")

    def self.disabled = new(path: nil)

    def initialize(path: DEFAULT_PATH)
      @path = path
    end

    # Whether the session `from` has asked to go elsewhere.
    def requested_for?(from)
      return false if from.nil?
      Records.read(@path)["from"] == from
    end

    # The requested id if it is one of `attachable`, and the request is gone either way.
    def take(attachable)
      id = Records.read(@path)["id"]
      clear
      attachable.include?(id) ? id : nil
    end

    def clear
      File.delete(@path) if @path
    rescue Errno::ENOENT
      nil
    end
  end
end
