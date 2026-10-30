# frozen_string_literal: true

module ClaudeInbox
  # Runs a helper command with its output captured, in a session of its own
  # so it never reaches the tab title (docs/cli-quirks.md).
  module Subprocess
    Result = Struct.new(:out, :err, :status) do
      def success? = status.success?
    end

    # `asdf exec`, which the ruby shim runs us through, puts the ruby it
    # picked ahead of every shim on PATH and names it in ASDF_INSTALL_PATH.
    # Left in place, every session runs our ruby whatever its project's
    # .tool-versions says.
    def self.unpinned(env)
      install = env["ASDF_INSTALL_PATH"] or return env
      prefix = File.join(install, "")
      path = env.fetch("PATH", "").split(File::PATH_SEPARATOR).reject { |dir| dir.start_with?(prefix) }
      env.reject { |k, _| k.start_with?("ASDF_INSTALL_") }.merge("PATH" => path.join(File::PATH_SEPARATOR))
    end

    # Children start in the environment from before Bundler, or every ruby a
    # session runs, in any project, loads our Gemfile, and from before asdf
    # pinned our ruby. Handed to exec rather than set on ENV, which the poll
    # and background threads share.
    CHILD_ENV = unpinned(defined?(Bundler.unbundled_env) ? Bundler.unbundled_env : ENV.to_h).freeze

    module_function

    # argv as exec and Process.spawn take it, with CHILD_ENV in place of
    # ours; `options` are Process.spawn's, such as chdir.
    def command(*argv, **options) = [CHILD_ENV, *argv, {unsetenv_others: true, **options}]

    # `input` is written before any output is read, so it is for the few
    # bytes a clipboard takes, not a stream.
    def capture(*argv, chdir: nil, input: nil)
      in_r, in_w = IO.pipe if input
      out_r, out_w = IO.pipe
      err_r, err_w = IO.pipe
      pid = fork do
        Process.setsid
        $stdin.reopen(input ? in_r : File::NULL)
        $stdout.reopen(out_w)
        $stderr.reopen(err_w)
        in_w&.close
        out_r.close
        err_r.close
        Dir.chdir(chdir) if chdir
        exec(*command(*argv))
      rescue SystemCallError => e
        $stderr.write(e.message)
        exit! 127
      end
      out_w.close
      err_w.close
      feed(in_r, in_w, input) if input
      out = +""
      err = +""
      readers = [out_r, err_r]
      until readers.empty?
        ready, = IO.select(readers)
        ready.each do |io|
          chunk = io.read_nonblock(65_536, exception: false)
          case chunk
          when :wait_readable then next
          when nil
            readers.delete(io)
            io.close
          else
            (io.equal?(out_r) ? out : err) << chunk
          end
        end
      end
      _, status = Process.wait2(pid)
      Result.new(out, err, status)
    end

    # A child that exits without reading closes the pipe under us.
    def feed(reader, writer, input)
      reader.close
      writer.write(input)
    rescue Errno::EPIPE
      nil
    ensure
      writer.close
    end
    private_class_method :feed
  end
end
