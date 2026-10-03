# frozen_string_literal: true

require_relative "records"

module ClaudeInbox
  # The sections as the screen shows them, written to a file for another
  # front end to read, so the triage rules run once, here. Rewritten when
  # the rows change and every HEARTBEAT seconds regardless, so a reader can
  # tell a quiet inbox from one that has quit.
  class Snapshot
    DEFAULT_PATH = File.join(Dir.home, ".config", "claude-inbox", "snapshot.json")
    HEARTBEAT = 5

    def self.disabled = new(path: nil)

    def initialize(path: DEFAULT_PATH)
      @path = path
      @body = nil
      @written_at = nil
      @mutex = Mutex.new
    end

    # Called from the poller's threads and the screen's alike.
    def write(sections, now)
      return unless @path
      body = sections.to_h { |name, rows| [name.to_s, rows.map { |row| row_hash(row) }] }
      @mutex.synchronize do
        return if body == @body && now.to_i - @written_at < HEARTBEAT
        @body = body
        @written_at = now.to_i
        Records.save(@path, {"version" => 1, "written_at" => @written_at, "sections" => body})
      end
    end

    private

    def row_hash(row)
      s = row.session
      pr = s.pr
      {
        "id" => row.key, "session" => s.session_id, "label" => row.label, "state" => s.effective_state, "actionable" => s.actionable?,
        "waiting" => s.waiting_on_work? || nil, "terminal" => s.terminal? || nil,
        "cwd" => s.cwd, "line" => s.summary, "wake_at" => row.wake_at, "remote" => s.remote_url,
        "pr" => pr && {"short" => pr.short, "state" => pr.state&.downcase, "url" => pr.url}
      }.compact
    end
  end
end
