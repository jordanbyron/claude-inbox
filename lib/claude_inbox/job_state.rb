# frozen_string_literal: true

require "json"

module ClaudeInbox
  # Reads ~/.claude/jobs/<id>/state.json, where the daemon keeps what
  # `claude agents --json` leaves out: the links it scanned out of the
  # transcript, and the colour `/color` set on the session.
  #
  # Never cached. A colour changes the moment you type `/color`, and a link
  # scan lands whenever the daemon next reads the transcript, so every poll
  # asks the file again.
  class JobState
    DEFAULT_DIR = File.join(Dir.home, ".claude", "jobs")

    def initialize(jobs_dir: DEFAULT_DIR)
      @jobs_dir = jobs_dir
    end

    def read(id)
      return {} unless id
      path = File.join(@jobs_dir, id, "state.json")
      return {} unless File.exist?(path)
      JSON.parse(File.read(path))
    rescue JSON::ParserError, SystemCallError
      {}
    end

    def color(id) = read(id)["color"]

    def children(id) = read(id)["children"] || []

    # Interactive sessions have no job file and so never carry a colour.
    def enrich(sessions)
      sessions.each { |s| s.color = color(s.id) }
    end
  end
end
