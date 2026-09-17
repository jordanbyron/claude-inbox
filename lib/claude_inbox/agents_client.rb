# frozen_string_literal: true

require "json"
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

    # The JSON reports Remote Control workers and local sub-agents as
    # `interactive`, same as a terminal you opened yourself. The process tree
    # tells them apart: a remote worker runs with --sdk-url, or is parented
    # by `claude rc`; a local sub-agent is parented by another `claude`
    # process instead of a shell. Sub-agents are dropped here rather than
    # merely flagged: attach lands on their parent, so there is nothing
    # useful to show or act on directly.
    def classify_origins(sessions)
      pids = sessions.select { |s| s.interactive? && s.pid }.map(&:pid)
      return sessions if pids.empty?
      remote, sub = origins_by_pid(pids)
      sessions.each { |s| s.origin = origin_for(s.pid, remote, sub) if s.interactive? }
      sessions.reject(&:subagent?)
    end

    def origin_for(pid, remote, sub)
      return :remote if remote.include?(pid)
      return :subagent if sub.include?(pid)
      :terminal
    end

    # pids => [remote_pids, subagent_pids], both subsets of `pids`.
    def origins_by_pid(pids)
      rows = ps_rows(pids)
      return [[], []] if rows.empty?
      by_sdk = rows.select { |_, _, cmd| cmd.include?("--sdk-url") }.map(&:first)
      parent_cmd = ps_commands(rows.map { |_, ppid, _| ppid }.uniq)
      rc_ppids = parent_cmd.select { |_, cmd| cmd.match?(/\bclaude rc\b/) }.keys
      claude_ppids = parent_cmd.select { |_, cmd| cmd.match?(/(^|\/)claude\b/) }.keys - rc_ppids
      remote = (by_sdk + rows.select { |_, ppid, _| rc_ppids.include?(ppid) }.map(&:first)).uniq
      sub = rows.select { |_, ppid, _| claude_ppids.include?(ppid) }.map(&:first) - remote
      [remote, sub]
    rescue Errno::ENOENT
      [[], []]
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
        File.write("/tmp/inbox-debug.log", "#{Time.now} watchdog saw #{cmd.inspect}\n", mode: "a") if ENV["CLAUDE_INBOX_DEBUG"]
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
    def initialize(path, logs: nil, remote_pids: [], subagent_pids: [])
      super()
      @path = path
      @logs = logs
      @remote_pids = remote_pids
      @subagent_pids = subagent_pids
    end

    # Fixture rows carry no process tree; classify each interactive row from
    # the pid lists the test hands in, otherwise as a terminal, then drop
    # sub-agents same as the real client does.
    def list(**)
      sessions = parse(File.read(@path))
      sessions.each { |s| s.origin = origin_for(s.pid, @remote_pids, @subagent_pids) if s.interactive? }
      sessions.reject(&:subagent?)
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
