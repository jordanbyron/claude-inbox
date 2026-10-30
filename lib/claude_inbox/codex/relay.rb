# frozen_string_literal: true

require "io/console"
require "pty"

module ClaudeInbox
  module Codex
    # Stands between the user's terminal and `codex resume` so that ← can
    # leave a thread as it leaves `claude attach`: Codex has no key that
    # hands back to its caller and refuses to bind ← to anything but the
    # cursor (docs/cli-quirks.md).
    class Relay
      # Where the composer's text starts, after "› ".
      PROMPT_COL = 3

      # ← as a terminal sends it: normal mode, application cursor mode, and
      # the kitty protocol's press, bare or with its event type.
      LEFT = ["\e[D", "\eOD", "\e[1;1D", "\e[1;1:1D"].freeze

      # Codex asks for kitty key releases, which can share a read with the
      # press they follow.
      RELEASE = /\e\[[\d;:]*:3[A-Za-z~]/

      # Codex ends each frame by putting the cursor in the composer and
      # showing it; while it is hidden there is no composer to leave from.
      CURSOR_SHOWN = /\e\[(\d+);(\d+)H\e\[\?25h/
      CURSOR_HIDDEN = "\e[?25l"

      # What Codex switches on that the inbox does not switch off when it
      # takes the screen back, for when Codex is ended before it can:
      # kitty keys, focus events, the mouse modes the inbox does not use,
      # application cursor and keypad.
      RESET = "\e[<u\e[?1004l\e[?1000l\e[?1002l\e[?1l\e>"

      WATCH_INTERVAL = 0.1

      # Runs `command`, Process.spawn's arguments, until it exits or the
      # user leaves with ←. True unless Codex failed on its own. The block,
      # polled alongside, ends the relay early when it answers true.
      #
      # The relay runs in a child process, where none of the inbox's threads
      # can hold up a keystroke; exit! keeps the inbox's at_exit hooks out
      # of it. It is told to stop by closing a pipe rather than by a signal,
      # which could land before it is ready for one, so it also stops if the
      # inbox dies.
      def self.run(command, tty: $stdin, out: $stdout, &stop)
        stopper, stop_now = IO.pipe
        pid = fork do
          ok = false
          stop_now.close
          ok = new(tty, out, stopper).relay(command)
        rescue => e
          out.write("\r\n#{e.class}: #{e.message}\r\n")
        ensure
          exit!(ok ? 0 : 1)
        end
        stopper.close
        watcher = stop && Thread.new do
          sleep WATCH_INTERVAL until stop.call
          stop_now.close
        end
        _, status = Process.wait2(pid)
        status.success?
      ensure
        watcher&.kill
        stop_now&.close unless stop_now&.closed?
      end

      def initialize(tty, out, stopper)
        @tty = tty
        @out = out
        @stopper = stopper
        @cursor = nil
        @leaving = false
      end

      def relay(command)
        reader, writer, pid = PTY.spawn(*command)
        codex = Thread.new { Process.wait2(pid).last }
        mode = @tty.console_mode
        @tty.raw!
        reader.winsize = @tty.winsize
        trap("WINCH") { reader.winsize = @tty.winsize }
        screen = Thread.new { show(reader) }
        pass_keys(writer) while codex.alive? && !@leaving
        left = @leaving
        stop(pid, codex)
        screen.join(1)
        left || codex.value.success?
      ensure
        @tty.console_mode = mode if mode
        @out.write(RESET)
        @out.flush
      end

      private

      def pass_keys(writer)
        ready, = IO.select([@tty, @stopper], nil, nil, WATCH_INTERVAL)
        return unless ready
        return @leaving = true if ready.include?(@stopper)
        keys = @tty.readpartial(4096)
        return writer.write(keys) unless leaves?(keys)
        @leaving = true
        # The ← release is still to come, and the inbox has no use for it.
        @tty.readpartial(4096) while @tty.wait_readable(WATCH_INTERVAL)
      rescue Errno::EIO
        nil
      end

      def leaves?(keys) = LEFT.include?(keys.gsub(RELEASE, "")) && @cursor&.last == PROMPT_COL

      def show(reader)
        tail = +""
        loop do
          chunk = reader.readpartial(16_384)
          @out.write(chunk)
          @out.flush
          # A sequence can straddle two reads.
          text = tail + chunk
          follow_cursor(text)
          tail = text[-32..] || text
        end
      rescue EOFError, Errno::EIO
        nil
      end

      def follow_cursor(text)
        shown_at = text.rindex(CURSOR_SHOWN)
        shown = shown_at && [$1.to_i, $2.to_i]
        hidden_at = text.rindex(CURSOR_HIDDEN)
        if shown_at && (hidden_at.nil? || shown_at > hidden_at)
          @cursor = shown
        elsif hidden_at
          @cursor = nil
        end
      end

      def stop(pid, codex)
        return unless codex.alive?
        Process.kill("TERM", pid)
        Process.kill("KILL", pid) unless codex.join(1)
      rescue Errno::ESRCH
        nil
      end
    end
  end
end
