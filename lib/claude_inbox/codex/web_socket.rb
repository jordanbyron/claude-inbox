# frozen_string_literal: true

require "securerandom"

module ClaudeInbox
  module Codex
    # The client half of RFC 6455 that Codex's daemon socket needs: one
    # upgrade, masked text frames out, text frames in, pings answered.
    # Nothing here knows JSON-RPC.
    class WebSocket
      class Error < StandardError; end

      CHUNK = 64 * 1024
      MAX_HEAD = 16 * 1024
      # The daemon's own cap, from the x-codex-websocket-max-unfragmented-message-bytes it sends.
      MAX_MESSAGE = 16 * 1024 * 1024

      TEXT = 0x1
      CLOSE = 0x8
      PING = 0x9
      PONG = 0xA

      def initialize(io, timeout:)
        @io = io
        @timeout = timeout
        @buf = +"".b
      end

      def handshake
        key = [SecureRandom.random_bytes(16)].pack("m0")
        @io.write("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
          "Sec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
        deadline = monotonic + @timeout
        until (i = @buf.index("\r\n\r\n"))
          raise Error, "the upgrade reply is over #{MAX_HEAD} bytes" if @buf.bytesize > MAX_HEAD
          fill(deadline)
        end
        status = @buf.slice!(0, i + 4).lines.first.to_s.strip
        raise Error, "the upgrade was refused: #{status}" unless status.match?(%r{\AHTTP/1\.1 101\b})
        self
      end

      def write_text(text) = write_frame(TEXT, text.b)

      # The next whole text message, answering pings on the way.
      def read_text
        deadline = monotonic + @timeout
        message = +"".b
        loop do
          fin, op, payload = read_frame(deadline)
          case op
          when PING then write_frame(PONG, payload)
          when CLOSE then raise Error, "the daemon closed the connection"
          when PONG then next
          else
            message << payload
            raise Error, "a message is over #{MAX_MESSAGE} bytes" if message.bytesize > MAX_MESSAGE
            return message.force_encoding(Encoding::UTF_8) if fin
          end
        end
      end

      def close
        write_frame(CLOSE, "".b)
      rescue SystemCallError, IOError
        nil
      ensure
        @io.close unless @io.closed?
      end

      private

      def read_frame(deadline)
        b0, b1 = take(2, deadline).unpack("CC")
        len = case b1 & 0x7f
        when 126 then take(2, deadline).unpack1("n")
        when 127 then take(8, deadline).unpack1("Q>")
        else b1 & 0x7f
        end
        raise Error, "a frame is over #{MAX_MESSAGE} bytes" if len > MAX_MESSAGE
        mask = take(4, deadline) if b1 & 0x80 != 0
        payload = take(len, deadline)
        [b0 & 0x80 != 0, b0 & 0x0f, mask ? masked(payload, mask) : payload]
      end

      # A client must mask every frame it sends, with a fresh key each time.
      def write_frame(op, payload)
        size = payload.bytesize
        head = [0x80 | op].pack("C")
        head << if size < 126 then [0x80 | size].pack("C")
        elsif size < 65_536 then [0x80 | 126, size].pack("Cn")
        else [0x80 | 127, size].pack("CQ>")
        end
        mask = SecureRandom.random_bytes(4)
        @io.write(head + mask + masked(payload, mask))
      end

      def masked(payload, mask)
        key = mask.bytes
        payload.bytes.each_with_index.map { |b, i| b ^ key[i % 4] }.pack("C*")
      end

      def take(n, deadline)
        fill(deadline) while @buf.bytesize < n
        @buf.slice!(0, n)
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def fill(deadline)
        loop do
          case (chunk = @io.read_nonblock(CHUNK, exception: false))
          when nil then raise Error, "the daemon closed the connection"
          when :wait_readable
            left = deadline - monotonic
            raise Error, "the daemon took too long" unless left > 0 && IO.select([@io], nil, nil, left)
          else return @buf << chunk
          end
        end
      end
    end
  end
end
