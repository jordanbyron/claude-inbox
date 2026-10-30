# frozen_string_literal: true

module ClaudeInbox
  # Interactive sessions report only `status`; folded into the background
  # vocabulary, an idle terminal is a finished turn and a waiting one needs you.
  INTERACTIVE_STATE = {"busy" => "working", "waiting" => "blocked", "idle" => "done"}.freeze

  # What the screen and the pane have always called the two states OSC 7501 renamed.
  STATE_WORDS = {"error" => "failed", "idle" => "stopped"}.freeze

  # One session in the words any harness can say, filled in by that
  # harness's adapter. Immutable, and the enrichers hand back copies via
  # `with`, so a list already given to another thread cannot move under it.
  # `line` is the session's own account of where it is, `in_flight` the work
  # it started that is still open, `remote` a session driven from another
  # device and `remote_control` one that can be. `branch` and `origin_url`
  # are the git branch and remote it works on, when its harness says. `actions` are what its
  # harness can do to it from here.
  Session = Data.define(
    :harness, :actions, :id, :cwd, :kind, :started_at, :created_at, :session_id, :name,
    :state, :blocked_kind, :pid, :status, :waiting_for, :line, :in_flight, :waiting_on_work,
    :remote, :remote_control, :remote_url, :color, :intent, :transcript_path, :pr_urls, :prs, :last_message_at,
    :branch, :origin_url
  ) do
    # Every member is optional so the adapter and the specs name only what
    # they have; prs is [] rather than nil so nobody asks whether
    # PullRequests has run. Without a record of when the session began, its
    # process start stands in.
    def initialize(prs: nil, pr_urls: nil, actions: nil, created_at: nil, **given)
      super(**self.class.members.to_h { |m| [m, nil] }, **given,
        prs: prs || [], pr_urls: pr_urls || [], actions: actions || [], created_at: created_at || given[:started_at])
    end

    def can?(action) = actions.include?(action)

    def background? = kind == "background"

    def interactive? = kind == "interactive"

    def attachable? = can?(:attach)

    def effective_state = state || INTERACTIVE_STATE[status] || "done"

    # A person drives a remote session, just from elsewhere; the adapter
    # drops the sessions nobody drives before anyone sees them.
    def remote? = remote == true

    def terminal? = interactive? && !remote?

    def remote_control? = remote_control == true

    # Selection handle: short id for background sessions, the UUID otherwise.
    def key = id || session_id

    # "working" covers an agent thinking and one gone quiet on work it started.
    def waiting_on_work? = effective_state == "working" && waiting_on_work == true

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
