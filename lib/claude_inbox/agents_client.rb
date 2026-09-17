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
      parse(out)
    end

    # Raw terminal replay for a session, or nil when the daemon can't serve it
    # (finished sessions whose process is gone report "job not found").
    def logs(id)
      out, _err, status = Open3.capture3(@bin, "logs", id)
      (status.success? && !out.empty?) ? out : nil
    end

    # Hands the terminal to the child; caller must have restored cooked mode.
    # Returns when the user detaches. Detaching never stops the session.
    def attach(id) = system(@bin, "attach", id)

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

    private

    def run(*argv)
      _out, err, status = Open3.capture3(*argv)
      raise Error, "#{argv[1]} failed: #{err.strip}" unless status.success?
      true
    end
  end

  # Reads a committed JSON fixture instead of the daemon.
  class FixtureClient < AgentsClient
    def initialize(path, logs: nil)
      super()
      @path = path
      @logs = logs
    end

    def list(**) = parse(File.read(@path))

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
