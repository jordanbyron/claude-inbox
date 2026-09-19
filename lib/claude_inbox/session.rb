# frozen_string_literal: true

module ClaudeInbox
  # Interactive sessions report only `status`; folded into the background
  # vocabulary, an idle terminal is a finished turn and a waiting one needs you.
  INTERACTIVE_STATE = {"busy" => "working", "waiting" => "blocked", "idle" => "done"}.freeze

  # One entry from `claude agents --json`. Immutable, and the enrichers hand
  # back copies via `with`, so a list already given to another thread cannot
  # move under it.
  Session = Data.define(
    :id, :cwd, :kind, :started_at, :session_id, :name,
    :state, :pid, :status, :waiting_for, :origin, :prs, :job_state
  ) do
    # Every member is optional so the parser and the specs name only what they
    # have; prs is [] rather than nil so nobody asks whether PullRequests has run.
    def initialize(id: nil, cwd: nil, kind: nil, started_at: nil, session_id: nil, name: nil,
      state: nil, pid: nil, status: nil, waiting_for: nil, origin: nil, prs: nil, job_state: nil)
      super(id: id, cwd: cwd, kind: kind, started_at: started_at, session_id: session_id, name: name,
            state: state, pid: pid, status: status, waiting_for: waiting_for, origin: origin, prs: prs || [], job_state: job_state)
    end

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

    # The JSON does not say where an interactive session is driven from;
    # AgentsClient reads it off the process tree: :terminal, :remote (a
    # claude.ai/code worker), :subagent or :headless (`claude -p` or an SDK
    # run); the last two are dropped before anyone downstream sees them.
    def remote? = origin == :remote

    def subagent? = origin == :subagent

    def headless? = origin == :headless

    # A remote worker is not unattended: a person drives it, just from claude.ai/code.
    def unattended? = subagent? || headless?

    def terminal? = interactive? && !remote? && !unattended?

    # Selection handle: short id for background sessions, the UUID otherwise.
    def key = id || session_id

    # "working" from the daemon means either the agent is thinking or it has
    # stopped and is waiting on work it started. JobState tells them apart.
    def waiting_on_work? = effective_state == "working" && job_state&.waiting_on_work? == true

    # From `/color`; interactive sessions have no job file, so never one.
    def color = job_state&.color

    def needs_you? = %w[blocked failed].include?(effective_state)

    def finished? = %w[done stopped].include?(effective_state)

    def alive? = !pid.nil?

    def display_name = name || id || session_id || "(unnamed)"

    def project = cwd ? File.basename(cwd) : ""

    def pr = prs.first
  end
end
