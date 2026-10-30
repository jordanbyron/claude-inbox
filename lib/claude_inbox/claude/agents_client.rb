# frozen_string_literal: true

require "json"
require_relative "../debug"
require_relative "../harnesses"
require_relative "job_state"
require_relative "../session"
require_relative "../subprocess"
require_relative "transcript"

module ClaudeInbox
  module Claude
    # The Claude adapter: the only place that shells out to `claude` or reads
    # what it keeps under ~/.claude, and it hands back finished Sessions.
    # Swap in FixtureClient for tests.
    class AgentsClient
      class Error < Harnesses::Error; end

      # The daemon's states in OSC 7501's words: a stopped session is idle, a failed one an error.
      STATES = {"working" => "working", "blocked" => "blocked", "done" => "done", "failed" => "error", "stopped" => "idle"}.freeze

      # `reap` is `rm` unasked, once a session has sat idle past Store::REAP_AFTER;
      # a harness whose delete can take unpushed work with it leaves it out.
      ACTIONS = %i[attach stop delete reap].freeze
      REMOTE_ACTIONS = %i[adopt].freeze

      # Process-tree origins of sessions nobody drives directly; see `origins`.
      UNATTENDED = %i[subagent headless].freeze

      attr_reader :jobs_dir

      def initialize(bin: "claude", jobs_dir: JobState::DEFAULT_DIR, transcripts: Transcript.new)
        @bin = bin
        @jobs_dir = jobs_dir
        @transcripts = transcripts
      end

      # => Array<Session>
      def list
        args = [@bin, "agents", "--json", "--all"]
        r = Subprocess.capture(*args)
        raise Error, "claude agents failed: #{r.err.strip}" unless r.success?
        rows = JSON.parse(r.out)
        ps = ps_rows(rows.filter_map { |h| h["pid"] if h["kind"] == "interactive" })
        sessions(rows, origins_from(ps), self.class.bridge_ids(ps))
      end

      # One row of the JSON as a Session, with its job file (nil when it has
      # none) and the process tree's word on where it is driven from.
      # `blocked_kind` stays nil: a blocked row carries no `waitingFor`, and an
      # interactive one's is free text such as "permission prompt".
      def self.session(h, job: nil, origin: nil, bridge: nil)
        remote = origin == :remote
        bridge ||= job&.bridge_id
        s = Session.new(
          harness: :claude,
          actions: actions_for(h["kind"], remote),
          id: h["id"],
          cwd: h["cwd"],
          kind: h["kind"],
          started_at: h["startedAt"] && Time.at(h["startedAt"] / 1000.0),
          created_at: job&.created_at,
          session_id: h["sessionId"],
          name: h["name"],
          state: h["state"] && STATES.fetch(h["state"], h["state"]),
          pid: h["pid"],
          status: h["status"],
          waiting_for: h["waitingFor"],
          in_flight: job&.in_flight_label,
          waiting_on_work: job&.waiting_on_work? == true,
          remote: remote,
          remote_control: remote || job&.remote_control? == true,
          remote_url: remote_url(bridge),
          color: job&.color,
          intent: job&.intent,
          transcript_path: job&.transcript_path,
          worktree_path: job&.worktree_path,
          pr_urls: job&.pr_urls
        )
        job ? s.with(line: job.summary(s.effective_state)) : s
      end

      def self.actions_for(kind, remote)
        if kind == "background" then ACTIONS
        elsif remote then REMOTE_ACTIONS
        else []
        end
      end

      # Where claude.ai/code shows a session. A background session with Remote
      # Control on records its bridge in the job file; a worker a `claude
      # remote-control` server spawned carries it on its command line.
      def self.remote_url(bridge) = bridge && "https://claude.ai/code/session_#{bridge.delete_prefix("cse_")}"

      # The page for a session just started, once its bridge is in the job file.
      def remote_url(id) = self.class.remote_url(JobState.read(id, jobs_dir: jobs_dir)&.bridge_id)

      WATCH_INTERVAL = 0.05

      # Hands the terminal to the child; caller must have restored cooked mode.
      # Returns when the user detaches. Detaching never stops the session.
      # False when the attach failed on its own, as a session that cannot be
      # woken does: the CLI prints why and exits 1.
      #
      # ← turns `claude attach` into `claude agents` in place, and nothing
      # switches off only that (docs/cli-quirks.md), so the watchdog kills the
      # child once it does. The block, polled alongside, ends the attach early
      # when it answers true. That is how a switch request from another front
      # end is honoured.
      def attach(session, &stop)
        pid = Process.spawn(*Subprocess.command(@bin, "attach", session.id))
        watchdog = Thread.new { kill_when_agents_view(pid, &stop) }
        _, status = Process.wait2(pid)
        status.success? || !status.exited?
      ensure
        watchdog&.kill
      end

      # True: the daemon stops whatever the session is doing.
      def stop(session) = run("stop", session.id)

      def rm(session) = run("rm", session.id)

      MODELS = %w[default fable opus sonnet haiku].freeze
      EFFORTS = %w[default low medium high xhigh max].freeze
      PERMISSION_MODES = %w[default acceptEdits auto plan bypassPermissions].freeze
      CHOICES = {model: MODELS, effort: EFFORTS, permission_mode: PERMISSION_MODES}.freeze
      def choices = CHOICES

      # The colors `/color` offers, in its order.
      COLORS = %w[default red blue green yellow purple orange pink cyan].freeze

      # Start a background session. Returns its short id. `claude --bg` takes
      # no color, and `/color` refuses a prompt after the color, so the color
      # goes into the job file the way `/color` would put it there.
      def spawn(prompt:, cwd:, color: nil, **opts)
        id = start_bg(self.class.spawn_args(@bin, prompt: prompt, **opts), cwd, "claude --bg")
        JobState.write_color(id, color, jobs_dir: @jobs_dir) if color
        id
      end

      # How a prompt attaches a file: the same @ mention the CLI's own prompt
      # takes, which reads an image as an image. Spaces are escaped the way
      # its path completion escapes them; a quoted path is not recognized.
      def self.mention(path) = "@" + path.gsub(" ", "\\ ")

      # The prompt goes after "--", where a leading dash is text rather than an
      # unknown option, and --remote-control sits just before it: its optional
      # name would otherwise eat the prompt (both checked on 2.1.282).
      def self.spawn_args(bin, prompt:, model: nil, effort: nil, permission_mode: nil, worktree: false, name: nil, remote: false)
        argv = [bin, "--bg"]
        {"--model" => model, "--effort" => effort, "--permission-mode" => permission_mode}.each do |flag, value|
          argv += [flag, value] if value
        end
        argv += ["--name", name] if name && !name.strip.empty?
        argv << "--worktree" if worktree
        argv << "--remote-control" if remote
        argv + ["--", prompt]
      end

      # Pull a conversation a `claude remote-control` server is serving into
      # the daemon, as a background session under the same id. Returns the
      # short id. The worker goes first: while it is open, a resume only makes
      # a copy. The server marks the session failed and leaves it be; the
      # resumed session gets a bridge of its own.
      def adopt(session_id:, cwd:, pid:)
        raise Error, "nothing to adopt yet — send it a message from your phone first" if transcript_empty?(cwd, session_id)
        Process.kill("TERM", pid)
        wait_gone(pid)
        start_bg(self.class.adopt_args(@bin, session_id), cwd, "claude --bg --resume")
      end

      def self.adopt_args(bin, session_id) = [bin, "--bg", "--resume", session_id, "--remote-control"]

      # Where the CLI keeps a directory's transcripts: every slash and dot in
      # the path becomes a dash.
      def self.transcript_path(cwd, session_id, home: Dir.home)
        File.join(home, ".claude", "projects", cwd.gsub(%r{[/.]}, "-"), "#{session_id}.jsonl")
      end

      # Flags that mark a claude process as one a program drives rather than one
      # you type in: the headless print mode and the SDK's stream protocol.
      HEADLESS_FLAGS = %w[-p --print --input-format --output-format].freeze

      # pid => origin, given `ps` for the sessions and for their parents.
      # A headless run's parent is whatever shell spawned it, not the claude
      # that asked for it, so only its own command line gives it away.
      def self.origins(rows, parent_cmd)
        rows.to_h do |pid, ppid, cmd|
          parent = parent_cmd[ppid].to_s
          origin =
            if cmd.include?("--sdk-url") || parent.match?(/\bclaude rc\b/) then :remote
            elsif headless?(cmd) then :headless
            elsif parent.match?(/(^|\/)claude\b/) then :subagent
            else :terminal
            end
          [pid, origin]
        end
      end

      # `ps` flattens quoting, so a prompt that mentions a flag reads the same
      # as the flag itself. Nobody types `claude "what does -p do"` into a
      # terminal often enough to matter; the false positive is accepted.
      def self.headless?(cmd) = cmd.split.drop(1).any? { |arg| HEADLESS_FLAGS.include?(arg) }

      # pid => bridge session id, for the workers a `claude remote-control`
      # server spawned: each is started with `--session-id cse_…`, the same id
      # a background session records as bridgeSessionId.
      def self.bridge_ids(rows)
        rows.filter_map { |pid, _, cmd| (m = cmd.match(/--session-id[= ](cse_\w+)/)) && [pid, m[1]] }.to_h
      end

      private

      # A worker nobody has messaged yet has an empty file, and the daemon
      # reports "source session not found" on resuming it.
      def transcript_empty?(cwd, session_id)
        path = self.class.transcript_path(cwd, session_id)
        File.exist?(path) && File.zero?(path)
      end

      def wait_gone(pid, timeout: 5)
        deadline = Time.now + timeout
        while Time.now < deadline
          Process.kill(0, pid)
          sleep 0.1
        end
        raise Error, "the worker #{pid} would not exit"
      rescue Errno::ESRCH
        nil
      end

      # The JSON reports Remote Control workers, local sub-agents and headless
      # runs as `interactive`, same as a terminal you opened yourself, each named
      # after its directory. The process tree tells them apart; see `origins`.
      # Everything but a terminal and a remote worker is dropped here rather than
      # merely flagged: attach lands on the session that asked for it, so there
      # is nothing useful to show or act on directly. Only a background session
      # has a job file.
      def sessions(rows, origins, bridges)
        found = rows.filter_map do |h|
          interactive = h["kind"] == "interactive"
          origin = origins.fetch(h["pid"], :terminal) if interactive
          next if UNATTENDED.include?(origin)
          job = JobState.read(h["id"], jobs_dir: @jobs_dir) if h["kind"] == "background"
          self.class.session(h, job: job, origin: origin, bridge: (bridges[h["pid"]] if interactive))
        end
        @transcripts.enrich(found)
      end

      def origins_from(rows)
        self.class.origins(rows, ps_commands(rows.map { |_, ppid, _| ppid }.uniq))
      end

      def ps_rows(pids)
        return [] if pids.empty?
        r = Subprocess.capture("ps", "-o", "pid=,ppid=,command=", "-p", pids.join(","))
        return [] unless r.success?
        r.out.lines.map { |l|
          pid, ppid, *cmd = l.split
          [pid.to_i, ppid.to_i, cmd.join(" ")]
        }
      end

      # pid => command, for the given parent pids.
      def ps_commands(ppids)
        return {} if ppids.empty?
        r = Subprocess.capture("ps", "-o", "pid=,command=", "-p", ppids.join(","))
        return {} unless r.success?
        r.out.lines.to_h { |l|
          pid, *cmd = l.split
          [pid.to_i, cmd.join(" ")]
        }
      end

      def kill_when_agents_view(pid, &stop)
        loop do
          sleep WATCH_INTERVAL
          cmd = Subprocess.capture("ps", "-o", "command=", "-p", pid.to_s).out
          break if cmd.empty?
          next unless cmd.split[1] == "agents" || stop&.call
          Debug.log("watchdog saw #{cmd.inspect}")
          Process.kill("TERM", pid)
          10.times do
            sleep 0.1
            break if Subprocess.capture("ps", "-o", "pid=", "-p", pid.to_s).out.empty?
          end
          Process.kill("KILL", pid)
          break
        end
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end

      def run(verb, id)
        r = Subprocess.capture(@bin, verb, id)
        raise Error, "#{verb} failed: #{r.err.strip}" unless r.success?
        true
      end

      def start_bg(argv, cwd, what)
        r = Subprocess.capture(*argv, chdir: cwd)
        raise Error, "#{what} failed: #{(r.err + r.out).strip}" unless r.success?
        r.out[/\b[0-9a-f]{8}\b/] || r.out.strip
      end
    end

    # Reads a committed JSON fixture instead of the daemon.
    class FixtureClient < AgentsClient
      def initialize(path, origins: {}, bridges: {})
        super(jobs_dir: File.join(File.dirname(path), "jobs"))
        @path = path
        @origins = origins
        @bridges = bridges
      end

      # Fixture rows carry no process tree.
      def list = sessions(JSON.parse(File.read(@path)), @origins, @bridges)

      # Stand-in child: prints, waits for a line, exits — enough to prove the
      # terminal round-trips through cooked mode and back.
      def attach(session) = system("sh", "-c", "printf 'fake attach to %s\\npress enter to detach: ' \"$1\"; read -r _", "attach", session.id)

      def stop(_session) = true

      def spawn(prompt:, cwd:, **)
        sleep 0.5
        "deadbeef"
      end

      def adopt(session_id:, cwd:, pid:) = "adop7ed0"

      def rm(_session) = nil
    end
  end
end
