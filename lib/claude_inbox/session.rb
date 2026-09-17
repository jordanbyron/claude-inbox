# frozen_string_literal: true

module ClaudeInbox
  STATES = %w[working blocked done failed stopped].freeze

  # Interactive sessions report only `status`; fold it into the same
  # vocabulary background sessions use. An idle terminal is a finished turn,
  # a waiting one needs you, a busy one is working.
  INTERACTIVE_STATE = {"busy" => "working", "waiting" => "blocked", "idle" => "done"}.freeze

  # One entry from `claude agents --json`. Plain value object; no behaviour
  # beyond parsing and a few predicates.
  Session = Struct.new(
    :id, :cwd, :kind, :started_at, :session_id, :name,
    :state, :pid, :status, :waiting_for
  ) do
    def self.from_hash(h)
      new(
        id: h["id"],
        cwd: h["cwd"],
        kind: h["kind"],
        started_at: h["startedAt"] && Time.at(h["startedAt"] / 1000.0),
        session_id: h["sessionId"],
        name: h["name"],
        state: h["state"],
        pid: h["pid"],
        status: h["status"],
        waiting_for: h["waitingFor"]
      )
    end

    def background? = kind == "background"

    def interactive? = kind == "interactive"

    # Only background sessions carry an id, and every action needs one.
    def actionable? = background? && !id.nil?

    def effective_state = state || INTERACTIVE_STATE[status] || "done"

    # Selection handle: short id for background sessions, the UUID otherwise.
    def key = id || session_id

    def needs_you? = %w[blocked failed].include?(effective_state)

    def finished? = %w[done stopped].include?(effective_state)

    def alive? = !pid.nil?

    def display_name = name || id || session_id || "(unnamed)"

    def project = cwd ? File.basename(cwd) : ""
  end
end
