# frozen_string_literal: true

module ClaudeInbox
  # Runs a helper command with stdout/stderr captured, in its own session so
  # it is not associated with our tty. Terminal.app (and others) put the
  # "active process" of the tty in the tab title; without this the title
  # flips to "claude" or "ps" on every poll.
  module Subprocess
    Result = Struct.new(:out, :err, :status) do
      def success? = status.success?
    end

    # Children start in the environment from before Bundler, or every ruby a
    # session runs, in any project, loads our Gemfile. Handed to exec rather
    # than set on ENV, which the poll and background threads share.
    CHILD_ENV = defined?(Bundler.unbundled_env) ? Bundler.unbundled_env.freeze : nil

    module_function

    # argv as exec and Process.spawn take it, with CHILD_ENV in place of ours.
    def command(*argv) = CHILD_ENV ? [CHILD_ENV, *argv, {unsetenv_others: true}] : argv

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
