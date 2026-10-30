# frozen_string_literal: true

require "json"
require "time"

module ClaudeInbox
  module Claude
    # What the daemon writes about a background session in
    # ~/.claude/jobs/<id>: state.json, and the last record of timeline.jsonl.
    # The only reader of those files, and the only writer: a new session's
    # color.
    #
    # `claude agents --json` says "working" both while the agent thinks and
    # while it sits idle on a shell or sub-agent it started, a teammate that
    # has long since reported included, and after a turn the CLI filed as
    # working. The timeline says whether the agent's own turn is over, the
    # state file what it is waiting on and what it left (docs/cli-quirks.md).
    #
    # Never cached. A color changes the moment you type `/color`, so every poll
    # asks the file again.
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

      # => JobState, or nil when there is no readable file for this id:
      # interactive sessions have no job file, and neither does one the daemon
      # has already forgotten.
      def self.read(id, jobs_dir:)
        return nil unless id
        new(JSON.parse(File.read(job_file(id, jobs_dir))), last_record(File.join(jobs_dir, id, "timeline.jsonl")))
      rescue JSON::ParserError, SystemCallError
        nil
      end

      TAIL = 16 * 1024

      # The timeline's last record, or nil without one. A record can run to
      # several KB of reply text, so the tail is read rather than the file.
      def self.last_record(path)
        size = File.size(path)
        tail = File.open(path, "rb") { |f| f.seek([size - TAIL, 0].max) && f.read }
        line = tail.split("\n").reject(&:empty?).last
        line && JSON.parse(line)
      rescue JSON::ParserError, SystemCallError
        nil
      end

      # The job file is there by the time `claude --bg` returns, and the daemon
      # updates it read-modify-write, so the color stays through work, stop and
      # respawn (checked on 2.1.296). A color is cosmetic: failing to write one
      # must not report a started session as failed.
      # ponytail: a daemon write racing this one can drop the color; re-apply on poll if that shows up.
      def self.write_color(id, color, jobs_dir:)
        path = job_file(id, jobs_dir)
        File.write("#{path}.tmp", JSON.generate(JSON.parse(File.read(path)).merge("color" => color)))
        File.rename("#{path}.tmp", path)
      rescue JSON::ParserError, SystemCallError
        nil
      end

      def self.job_file(id, jobs_dir) = File.join(jobs_dir, id, "state.json")
      private_class_method :job_file

      attr_reader :pr_urls, :transcript_path, :worktree_path, :color, :intent, :bridge_id, :created_at

      def initialize(hash, last_record = nil)
        @state = hash["state"]
        @last_text = (last_record || {})["text"].to_s
        @detail = hash["detail"]
        @needs = hash["needs"]
        @result = (hash["output"] || {})["result"]
        @tempo = hash["tempo"]
        @kinds = (hash["fan"] || []).filter_map { |f| f["kind"] }
        @tasks = (hash["inFlight"] || {})["tasks"].to_i
        @pr_urls = (hash["children"] || []).filter_map { |c| c["href"] if c["kind"] == "pr" }
        @transcript_path = hash["linkScanPath"]
        @worktree_path = hash["worktreePath"]
        @color = hash["color"]
        @intent = hash["intent"]
        @bridge_id = hash["bridgeSessionId"]
        @created_at = time(hash["createdAt"])
        @flags = hash["respawnFlags"] || []
      end

      # The flags the session was started with, which the daemon puts back on
      # a wake, are the only record of Remote Control being on it.
      def remote_control? = flags.include?("--remote-control")

      # The agent's own turn has ended. A turn ends with a timeline record
      # carrying the reply, and everything until the next reply is a record
      # without one: the prompt that starts a turn, each tool call. A turn a
      # notification starts shows nothing until its first tool call, so this
      # runs a few seconds late for one (docs/cli-quirks.md).
      def turn_over? = !last_text.strip.empty?

      # The state the session filed with its last reply, when it is one a
      # reply leaves behind: "blocked" or "done". Nil for "working", which a
      # reply read as work in progress files too. Only meaningful once the
      # turn is over: the state file lags the prompt that starts a turn until
      # the first tool call.
      def settled_state = %w[blocked done].include?(state) ? state : nil

      def in_flight? = tasks.positive?

      # The agent itself is not thinking. On its own this means little — a
      # session whose process died leaves the same reading behind — so it
      # only says something paired with `in_flight?`.
      def agent_idle? = tempo == "idle"

      # What the session needs while blocked, what it produced once done,
      # otherwise its status line; nil before it has said anything.
      def summary(state)
        line =
          case state
          when "blocked" then needs || detail
          when "done" then result || detail
          else detail
          end
        line = line.to_s.gsub(/\s+/, " ").strip
        line.empty? ? nil : line
      end

      # "1 shell", "2 agents · 1 shell". Falls back to a bare count for a state
      # file that counts the open tasks without naming them.
      def in_flight_label
        return nil unless in_flight?
        return count_label if kinds.empty?
        kinds.tally.map { |kind, n| "#{n} #{plural(KIND_WORDS.fetch(kind, kind), n)}" }.join(" · ")
      end

      private

      attr_reader :state, :last_text, :detail, :needs, :result, :tempo, :kinds, :tasks, :flags

      def count_label = "#{tasks} #{plural("task", tasks)}"

      def plural(word, n) = (n == 1) ? word : "#{word}s"

      def time(iso)
        iso && Time.iso8601(iso)
      rescue ArgumentError
        nil
      end
    end
  end
end
