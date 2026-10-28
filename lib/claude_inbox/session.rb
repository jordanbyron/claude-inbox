# frozen_string_literal: true

module ClaudeInbox
  # Interactive sessions report only `status`; folded into the background
  # vocabulary, an idle terminal is a finished turn and a waiting one needs you.
  INTERACTIVE_STATE = {"busy" => "working", "waiting" => "blocked", "idle" => "done"}.freeze

  # The daemon's states in OSC 7501's words: a stopped session is idle, a failed one an error.
  CLAUDE_STATE = {"working" => "working", "blocked" => "blocked", "done" => "done", "failed" => "error", "stopped" => "idle"}.freeze

  # What the screen and the pane have always called the two states OSC 7501 renamed.
  STATE_WORDS = {"error" => "failed", "idle" => "stopped"}.freeze

  # One entry from `claude agents --json`. Immutable, and the enrichers hand
  # back copies via `with`, so a list already given to another thread cannot
  # move under it.
  Session = Data.define(
    :id, :cwd, :kind, :started_at, :session_id, :name,
    :state, :blocked_kind, :pid, :status, :waiting_for, :origin, :prs, :job_state, :bridge_id, :last_message_at
  ) do
    # Every member is optional so the parser and the specs name only what they
    # have; prs is [] rather than nil so nobody asks whether PullRequests has run.
    def initialize(prs: nil, **given)
      super(**self.class.members.to_h { |m| [m, nil] }, **given, prs: prs || [])
    end

    # `blocked_kind` (permission, question or auth) stays nil: a blocked row
    # in the JSON carries no `waitingFor`, and an interactive one's is free
    # text such as "permission prompt".
    def self.from_hash(h)
      new(
        id: h["id"],
        cwd: h["cwd"],
        kind: h["kind"],
        started_at: h["startedAt"] && Time.at(h["startedAt"] / 1000.0),
        session_id: h["sessionId"],
        name: h["name"],
        state: h["state"] && CLAUDE_STATE.fetch(h["state"], h["state"]),
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

    # Where claude.ai/code shows this session. A background session with
    # Remote Control on records its bridge in the job file; a worker a
    # `claude remote-control` server spawned carries it on its command line.
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

    # A respawn moves `started_at` to the new process; the job file keeps
    # when the session itself began.
    def created_at = job_state&.created_at || started_at

    # The prompt this session was started with.
    def intent = job_state&.intent

    # The session's own one-line account of where it is, the same line
    # `claude agents` prints under a row. Nil without a job file.
    def summary = job_state&.summary(effective_state)

    def needs_you? = %w[blocked error].include?(effective_state)

    def finished? = %w[done idle].include?(effective_state)

    def alive? = !pid.nil?

    def display_name = name || id || session_id || "(unnamed)"

    def project = cwd ? File.basename(cwd) : ""

    # The PR you would act on. One only mentioned loses to any live one.
    def pr = prs.each_with_index.min_by { |pr, i| [headline_rank(pr), i] }&.first

    # Oldest first so a stack reads up from its base; trouble is the
    # headline's job, not this order's.
    def prs_by_status = prs.each_with_index.sort_by { |pr, i| [*status_order(pr), i] }.map(&:first)

    private

    def headline_rank(pr)
      if mentioned?(pr) then 4
      elsif pr.needs_you? then 0
      elsif pr.health == "CONFLICTING" then 1
      elsif !pr.resolved? then 2
      else 3
      end
    end

    def status_order(pr)
      age = pr.number.to_i
      if mentioned?(pr) then [3, age]
      elsif pr.state == "OPEN" then [0, age]
      elsif pr.state == "DRAFT" then [1, age]
      else [2, -age]
      end
    end

    # Unknown, or resolved before the session began (as Row#settled? judges).
    def mentioned?(pr) = !pr.known? || pr.resolved_before?(created_at)
  end
end
