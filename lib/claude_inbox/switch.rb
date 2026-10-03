# frozen_string_literal: true

require_relative "records"

module ClaudeInbox
  # A request from another front end to attach to a different session: one
  # file, written by the asker and taken by the inbox holding the terminal.
  # Only an inbox attached to a session can act on it, which is why the
  # asker gives up on a request nobody takes.
  class Switch
    DEFAULT_PATH = File.join(Dir.home, ".config", "claude-inbox", "switch.json")

    def self.disabled = new(path: nil)

    def initialize(path: DEFAULT_PATH)
      @path = path
    end

    def request(id, now) = @path && Records.save(@path, {"id" => id, "at" => now.to_i})

    def requested? = !@path.nil? && File.exist?(@path)

    # The requested id, and the request is gone; nil without one.
    def take
      id = Records.read(@path)["id"]
      clear
      (id.is_a?(String) && !id.empty?) ? id : nil
    end

    def clear
      File.delete(@path) if @path
    rescue Errno::ENOENT
      nil
    end
  end
end
