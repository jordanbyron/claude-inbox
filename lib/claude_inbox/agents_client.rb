# frozen_string_literal: true

require "json"
require_relative "debug"
require_relative "subprocess"

module ClaudeInbox
  # The only place that shells out to `claude`. Returns plain Ruby values.
  # Swap in FixtureClient for tests.
  class AgentsClient
    class Error < StandardError; end

    def initialize(bin: "claude")
      @bin = bin
    end

    # => Array<Session>
    def list(all: true, cwd: nil)
      args = [@bin, "agents", "--json"]
      args << "--all" if all
      args += ["--cwd", cwd] if cwd
      r = Subprocess.capture(*args)
      raise Error, "claude agents failed: #{r.err.strip}" unless r.success?
      classify_origins(parse(r.out))
    end

    # Raw terminal replay for a session, or nil when the daemon can't serve it
    # (finished sessions whose process is gone report "job not found").
    def logs(id)
      r = Subprocess.capture(@bin, "logs", id)
      (r.success? && !r.out.empty?) ? r.out : nil
    end

    # Poll interval for the agents-view watchdog below.
    WATCH_INTERVAL = 0.05

    # Hands the terminal to the child; caller must have restored cooked mode.
    # Returns when the user detaches. Detaching never stops the session.
    #
    # Pressing ← inside an attached session detaches it and then `claude
    # attach` execs itself in place as `claude agents` (same pid). There is
    # no flag or env var that suppresses only that relaunch: the one switch
    # that exists disables attach too. So we watch the child's command line
    # and, the moment it becomes the agents view, terminate it. The user then
    # lands back in the inbox instead of native agent view.
    def attach(id)
      pid = Process.spawn(@bin, "attach", id)
      watchdog = Thread.new { kill_when_agents_view(pid) }
      _, status = Process.wait2(pid)
      status
    ensure
      watchdog&.kill
    end

    def stop(id) = run(@bin, "stop", id)

    def rm(id) = run(@bin, "rm", id)

    def respawn(id) = run(@bin, "respawn", id)

    def daemon_alive? = Subprocess.capture(@bin, "daemon", "status").success?

    MODELS = %w[default fable opus sonnet haiku].freeze
    EFFORTS = %w[default low medium high xhigh max].freeze
    PERMISSION_MODES = %w[default acceptEdits auto plan bypassPermissions].freeze

    # Start a background session. Returns its short id.
    def spawn(prompt:, cwd:, **opts)
      argv = self.class.spawn_args(@bin, prompt: prompt, **opts)
      r = Subprocess.capture(*argv, chdir: cwd)
      raise Error, "claude --bg failed: #{(r.err + r.out).strip}" unless r.success?
      r.out[/\b[0-9a-f]{8}\b/] || r.out.strip
    end

    # Pure so it can be tested: "default" means leave the flag off.
    def self.spawn_args(bin, prompt:, model: nil, effort: nil, permission_mode: nil, worktree: false, name: nil)
      argv = [bin, "--bg", prompt]
      argv += ["--model", model] if model && model != "default"
      argv += ["--effort", effort] if effort && effort != "default"
      argv += ["--permission-mode", permission_mode] if permission_mode && permission_mode != "default"
      argv += ["--name", name] if name && !name.strip.empty?
      argv << "--worktree" if worktree
      argv
    end

    def parse(json)
      JSON.parse(json).map { |h| Session.from_hash(h) }
    end

    # Flags that mark a claude process as one a program drives rather than one
    # you type in: the headless print mode and the SDK's stream protocol.
    HEADLESS_FLAGS = %w[-p --print --input-format --output-format].freeze

    # The JSON reports Remote Control workers, local sub-agents and headless
    # runs as `interactive`, same as a terminal you opened yourself, each named
    # after its directory. The process tree tells them apart; see `origins`.
    # Everything but a terminal and a remote worker is dropped here rather than
    # merely flagged: attach lands on the session that asked for it, so there
    # is nothing useful to show or act on directly.
    def classify_origins(sessions)
      pids = sessions.select { |s| s.interactive? && s.pid }.map(&:pid)
      return sessions if pids.empty?
      assign_origins(sessions, origins_by_pid(pids))
    end

    # Tags each interactive session with where it is driven from (pid =>
    # origin, terminal when unlisted) and drops the unattended ones, whose
    # parent is the row worth showing.
    def assign_origins(sessions, origins)
      sessions.each { |s| s.origin = origins.fetch(s.pid, :terminal) if s.interactive? }
      sessions.reject(&:unattended?)
    end

    # pid => origin, given `ps` for the sessions and for their parents. Pure.
    #
    #   :remote    a Remote Control worker: --sdk-url, or a `claude rc` parent
    #   :headless  `claude -p "..."` or an SDK stream run. Its parent is
    #              whatever shell spawned it, not the claude that asked for
    #              it, so only its own command line gives it away
    #   :subagent  parented by another claude process
    #   :terminal  everything else, which is a claude you are sitting in
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

    def origins_by_pid(pids)
      rows = ps_rows(pids)
      return {} if rows.empty?
      self.class.origins(rows, ps_commands(rows.map { |_, ppid, _| ppid }.uniq))
    rescue Errno::ENOENT
      {}
    end

    def ps_rows(pids)
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

    private

    def kill_when_agents_view(pid)
      loop do
        sleep WATCH_INTERVAL
        cmd = Subprocess.capture("ps", "-o", "command=", "-p", pid.to_s).out
        break if cmd.empty?
        next unless cmd.split[1] == "agents"
        Debug.log("watchdog saw #{cmd.inspect}")
        Process.kill("TERM", pid)
        sleep 1
        Process.kill("KILL", pid)
        break
      end
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end

    def run(*argv)
      r = Subprocess.capture(*argv)
      raise Error, "#{argv[1]} failed: #{r.err.strip}" unless r.success?
      true
    end
  end

  # Reads a committed JSON fixture instead of the daemon.
  class FixtureClient < AgentsClient
    def initialize(path, logs: nil, origins: {})
      super()
      @path = path
      @logs = logs
      @origins = origins
    end

    # Fixture rows carry no process tree; tag each interactive row from the
    # pid => origin map the test hands in, otherwise as a terminal, then drop
    # the unattended ones same as the real client does.
    def list(**)
      assign_origins(parse(File.read(@path)), @origins)
    end

    def logs(_id) = @logs

    # Stand-in child: prints, waits for a line, exits — enough to prove the
    # terminal round-trips through cooked mode and back.
    def attach(id) = system("sh", "-c", "printf 'fake attach to %s\\npress enter to detach: ' \"$1\"; read -r _", "attach", id)

    def stop(_id) = true

    def spawn(prompt:, cwd:, **)
      sleep 0.5
      "deadbeef"
    end

    def rm(_id) = true

    def respawn(_id) = true

    def daemon_alive? = true
  end
end
