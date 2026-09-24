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
    :state, :pid, :status, :waiting_for, :origin, :prs, :job_state, :bridge_id
  ) do
    # Every member is optional so the parser and the specs name only what they
    # have; prs is [] rather than nil so nobody asks whether PullRequests has run.
    def initialize(prs: nil, **given)
      super(**self.class.members.to_h { |m| [m, nil] }, **given, prs: prs || [])
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

    # Where claude.ai/code shows this session. Every background session
    # registers a bridge and records it in the job file; a worker a `claude
    # remote-control` server spawned carries it on its command line.
    def remote_url
      bridge = bridge_id || job_state&.bridge_id
      bridge && "https://claude.ai/code/session_#{bridge.delete_prefix("cse_")}"
    end

    # Driven from claude.ai/code as well as from here, not only followed there.
    def remote_control? = remote? || job_state&.remote_control? == true

    # Selection handle: short id for background sessions, the UUID otherwise.
    def key = id || session_id

    # "working" from the daemon means either the agent is thinking or it has
    # stopped and is waiting on work it started. JobState tells them apart.
    def waiting_on_work? = effective_state == "working" && job_state&.waiting_on_work? == true

    # From `/color`; interactive sessions have no job file, so never one.
    def color = job_state&.color

    # The prompt this session was started with.
    def intent = job_state&.intent

    # The session's own one-line account of where it is, the same line
    # `claude agents` prints under a row: what it needs while blocked, what
    # it produced once done, otherwise its status line. Nil without a job
    # file, or before the session has said anything.
    def summary
      return nil unless job_state
      line =
        case effective_state
        when "blocked" then job_state.needs || job_state.detail
        when "done" then job_state.result || job_state.detail
        else job_state.detail
        end
      line = line.to_s.gsub(/\s+/, " ").strip
      line.empty? ? nil : line
    end

    def needs_you? = %w[blocked failed].include?(effective_state)

    def finished? = %w[done stopped].include?(effective_state)

    def alive? = !pid.nil?

    def display_name = name || id || session_id || "(unnamed)"

    def project = cwd ? File.basename(cwd) : ""

    def pr = prs.first
  end
end
