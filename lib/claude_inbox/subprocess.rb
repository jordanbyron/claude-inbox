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

    module_function

    def capture(*argv, chdir: nil)
      out_r, out_w = IO.pipe
      err_r, err_w = IO.pipe
      pid = fork do
        Process.setsid
        $stdin.reopen(File::NULL)
        $stdout.reopen(out_w)
        $stderr.reopen(err_w)
        out_r.close
        err_r.close
        Dir.chdir(chdir) if chdir
        exec(*argv)
      rescue SystemCallError => e
        $stderr.write(e.message)
        exit! 127
      end
      out_w.close
      err_w.close
      out = +""
      err = +""
      readers = [out_r, err_r]
      until readers.empty?
        ready, = IO.select(readers)
        ready.each do |io|
          case (chunk = io.read_nonblock(65_536, exception: false))
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
  end
end
