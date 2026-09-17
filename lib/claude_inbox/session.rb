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
    :state, :pid, :status, :waiting_for, :origin, :prs
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

    # Where an interactive session is driven from. The JSON does not say;
    # AgentsClient fills this in from the process tree, then drops
    # :subagent rows before anyone downstream sees them.
    #   :terminal  a claude you opened in a terminal yourself
    #   :remote    a Remote Control worker driven from claude.ai/code, unreachable from here
    #   :subagent  a sub-agent spawned locally by another claude process; attach to that parent instead
    def remote? = origin == :remote

    def subagent? = origin == :subagent

    def terminal? = interactive? && !remote? && !subagent?

    # Selection handle: short id for background sessions, the UUID otherwise.
    def key = id || session_id

    def needs_you? = %w[blocked failed].include?(effective_state)

    def finished? = %w[done stopped].include?(effective_state)

    def alive? = !pid.nil?

    def display_name = name || id || session_id || "(unnamed)"

    def project = cwd ? File.basename(cwd) : ""

    # Pull requests tied to this session; PullRequests fills these in.
    def prs = self[:prs] || []

    def pr = prs.first
  end
end
