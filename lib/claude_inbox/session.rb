# frozen_string_literal: true

module ClaudeInbox
  # Interactive sessions report only `status`; fold it into the same
  # vocabulary background sessions use. An idle terminal is a finished turn,
  # a waiting one needs you, a busy one is working.
  INTERACTIVE_STATE = {"busy" => "working", "waiting" => "blocked", "idle" => "done"}.freeze

  # One entry from `claude agents --json`. Immutable value object; no
  # behaviour beyond parsing and a few predicates. AgentsClient, JobState and
  # PullRequests each hand back a copy with one more member set (`with`),
  # never a changed original, so a list already handed to another thread
  # cannot move under it.
  Session = Data.define(
    :id, :cwd, :kind, :started_at, :session_id, :name,
    :state, :pid, :status, :waiting_for, :origin, :prs, :job_state
  ) do
    # Every member is optional so the parser and the specs can name only the
    # ones they have. A session nobody has been past yet answers [] for prs
    # rather than nil, so nobody has to know whether PullRequests has.
    def initialize(id: nil, cwd: nil, kind: nil, started_at: nil, session_id: nil, name: nil,
      state: nil, pid: nil, status: nil, waiting_for: nil, origin: nil, prs: [], job_state: nil)
      super
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

    # Where an interactive session is driven from. The JSON does not say;
    # AgentsClient reads it off the process tree, then drops :subagent rows
    # before anyone downstream sees them.
    #   :terminal  a claude you opened in a terminal yourself
    #   :remote    a Remote Control worker driven from claude.ai/code, unreachable from here
    #   :subagent  a sub-agent spawned locally by another claude process; attach to that parent instead
    #   :headless  a `claude -p` or SDK run some program started; it answers and exits
    def remote? = origin == :remote

    def subagent? = origin == :subagent

    def headless? = origin == :headless

    # Nobody is sitting in either of these. A remote worker is not included:
    # a person drives that one, just from claude.ai/code rather than here.
    def unattended? = subagent? || headless?

    def terminal? = interactive? && !remote? && !unattended?

    # Selection handle: short id for background sessions, the UUID otherwise.
    def key = id || session_id

    # "working" from the daemon means either the agent is thinking or it has
    # stopped and is waiting on work it started. JobState tells them apart.
    def waiting_on_work? = effective_state == "working" && job_state&.waiting_on_work? == true

    # The color `/color` gave the session. Interactive sessions have no job
    # file and so never carry one.
    def color = job_state&.color

    def needs_you? = %w[blocked failed].include?(effective_state)

    def finished? = %w[done stopped].include?(effective_state)

    def alive? = !pid.nil?

    def display_name = name || id || session_id || "(unnamed)"

    def project = cwd ? File.basename(cwd) : ""

    # First of the pull requests tied to this session; PullRequests finds them.
    def pr = prs.first
  end
end
