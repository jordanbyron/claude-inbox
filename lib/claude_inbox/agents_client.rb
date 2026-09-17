# frozen_string_literal: true

require "json"
require "open3"

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
      out, err, status = Open3.capture3(*args)
      raise Error, "claude agents failed: #{err.strip}" unless status.success?
      classify_origins(parse(out))
    end

    # Raw terminal replay for a session, or nil when the daemon can't serve it
    # (finished sessions whose process is gone report "job not found").
    def logs(id)
      out, _err, status = Open3.capture3(@bin, "logs", id)
      (status.success? && !out.empty?) ? out : nil
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

    def daemon_alive?
      _out, _err, status = Open3.capture3(@bin, "daemon", "status")
      status.success?
    end

    def parse(json)
      JSON.parse(json).map { |h| Session.from_hash(h) }
    end

    # The JSON reports Remote Control workers as `interactive`, same as a
    # terminal you opened yourself. The process tree tells them apart: a
    # remote worker runs with --sdk-url under a `claude rc` parent.
    def classify_origins(sessions)
      pids = sessions.select { |s| s.interactive? && s.pid }.map(&:pid)
      return sessions if pids.empty?
      remote = remote_pids(pids)
      sessions.each { |s| s.origin = remote.include?(s.pid) ? :remote : :terminal if s.interactive? }
      sessions
    end

    def remote_pids(pids)
      out, _err, status = Open3.capture3("ps", "-o", "pid=,ppid=,command=", "-p", pids.join(","))
      return [] unless status.success?
      rows = out.lines.map { |l|
        pid, ppid, *cmd = l.split
        [pid.to_i, ppid.to_i, cmd.join(" ")]
      }
      by_sdk = rows.select { |_, _, cmd| cmd.include?("--sdk-url") }.map(&:first)
      parents = rows.map { |_, ppid, _| ppid }.uniq
      pout, _perr, pstatus = Open3.capture3("ps", "-o", "pid=,command=", "-p", parents.join(","))
      rc_parents = pstatus.success? ? pout.lines.select { |l| l.split[1..].join(" ").match?(/\bclaude rc\b/) }.map { |l| l.split.first.to_i } : []
      by_rc = rows.select { |_, ppid, _| rc_parents.include?(ppid) }.map(&:first)
      (by_sdk + by_rc).uniq
    rescue Errno::ENOENT
      []
    end

    private

    def kill_when_agents_view(pid)
      loop do
        sleep WATCH_INTERVAL
        cmd = `ps -o command= -p #{pid.to_i} 2>/dev/null`
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
      _out, err, status = Open3.capture3(*argv)
      raise Error, "#{argv[1]} failed: #{err.strip}" unless status.success?
      true
    end
  end

  # Reads a committed JSON fixture instead of the daemon.
  class FixtureClient < AgentsClient
    def initialize(path, logs: nil, remote_pids: [])
      super()
      @path = path
      @logs = logs
      @remote_pids = remote_pids
    end

    # Fixture rows carry no process tree; treat every interactive row as remote
    # when `remote_pids` is given, otherwise as a terminal.
    def list(**)
      parse(File.read(@path)).each { |s| s.origin = @remote_pids.include?(s.pid) ? :remote : :terminal if s.interactive? }
    end

    def logs(_id) = @logs

    # Stand-in child: prints, waits for a line, exits — enough to prove the
    # terminal round-trips through cooked mode and back.
    def attach(id) = system("sh", "-c", "printf 'fake attach to %s\\npress enter to detach: ' \"$1\"; read -r _", "attach", id)

    def stop(_id) = true

    def rm(_id) = true

    def respawn(_id) = true

    def daemon_alive? = true
  end
end
