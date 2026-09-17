# frozen_string_literal: true

require "json"

module ClaudeInbox
  # What the daemon writes about a background session in
  # ~/.claude/jobs/<id>/state.json. The only reader of that file.
  #
  # `claude agents --json` reports one word, `state`, and "working" covers two
  # different situations: the agent is thinking, or the agent is idle and
  # something it started earlier — a watch shell, a sub-agent — is still open.
  # The file tells them apart: `tempo` is the agent's own pulse, `fan` names
  # each outstanding piece of work, and `detail` is the session's own status
  # line. It also carries the PR links the daemon scanned out of the
  # transcript, which PullRequests reads through here.
  #
  # The file says what a session is *doing*, never whether it is *alive*: the
  # session's own process writes it, so one that dies hard leaves it frozen
  # mid-turn, claiming "working" for ever. Liveness stays with the daemon.
  class JobState
    DEFAULT_DIR = File.join(Dir.home, ".claude", "jobs")

    # The daemon's names for the things a session waits on, in ours.
    KIND_WORDS = {
      "shell" => "shell",
      "local_bash" => "shell",
      "teammate" => "agent",
      "in_process_teammate" => "agent",
      "monitor" => "monitor"
    }.freeze

    # Fills `job_state` on every background session. Interactive sessions have
    # no job file, and neither does one the daemon has already forgotten.
    def self.enrich(sessions, jobs_dir: DEFAULT_DIR)
      sessions.each { |s| s.job_state = read(s.id, jobs_dir: jobs_dir) if s.background? }
      sessions
    end

    # => JobState, or nil when there is no readable file for this id.
    def self.read(id, jobs_dir: DEFAULT_DIR)
      return nil unless id
      new(JSON.parse(File.read(File.join(jobs_dir, id, "state.json"))))
    rescue JSON::ParserError, SystemCallError
      nil
    end

    attr_reader :detail, :tempo, :kinds, :tasks, :pr_urls

    def initialize(hash)
      @detail = hash["detail"]
      @tempo = hash["tempo"]
      @kinds = (hash["fan"] || []).filter_map { |f| f["kind"] }
      @tasks = (hash["inFlight"] || {})["tasks"].to_i
      @pr_urls = (hash["children"] || []).select { |c| c["kind"] == "pr" && c["href"] }.map { |c| c["href"] }
    end

    # The agent itself is not thinking. On its own this means little — a
    # session whose process died leaves the same reading behind — so it only
    # says something paired with work still in flight.
    def agent_idle? = tempo == "idle"

    def in_flight? = tasks.positive?

    # True when the agent has stopped and is only waiting on what it started.
    def waiting_on_work? = agent_idle? && in_flight?

    # "1 shell", "2 agents · 1 shell". Falls back to a bare count for a state
    # file that counts the open tasks without naming them.
    def in_flight_label
      return nil unless in_flight?
      return count_label if kinds.empty?
      kinds.tally.map { |kind, n| "#{n} #{plural(KIND_WORDS.fetch(kind, kind), n)}" }.join(" · ")
    end

    private

    def count_label = "#{tasks} #{plural("task", tasks)}"

    def plural(word, n) = (n == 1) ? word : "#{word}s"
  end
end
