# frozen_string_literal: true

require_relative "../dialog"
require_relative "../text"

module ClaudeInbox
  module Remote
    # `N`: whether the listener is up, and how a phone reaches it.
    class PairingDialog < Dialog
      WIDTH = 76
      FIREWALL = {
        off: "firewall: off",
        on: "firewall: on · allow ruby when macOS asks",
        block_all: "firewall: blocking all incoming connections · nothing reaches this"
      }.freeze

      def initialize(snapshot)
        super(:pairing, nil)
        @snapshot = snapshot
        @asking = false
      end

      def title = " Pair a phone "

      def lines(width, _caret)
        s = @snapshot.call
        out = ["  " + state_line(s)]
        out += (s.state == :listening) ? listening_lines(s) : advice(s, width)
        if s.recent.any?
          out << "" << "  recent:"
          out += s.recent.reverse.map { |o| "    #{o.at.strftime("%H:%M")}  #{o.via}  #{o.result}#{" ×#{o.count}" if o.count > 1}" }
        end
        out << ""
        out += key_lines(s)
        out.map { |line| Text.truncate(line, width) }
      end

      # => :cancel, :copy, :rotate, or nil
      def press(name, key)
        if @asking
          @asking = false
          return (key == "y") ? :rotate : nil
        end
        return :cancel if name == :escape || key == "q"
        return nil unless @snapshot.call.state == :listening
        case key
        when "c" then :copy
        when "r"
          @asking = true
          nil
        end
      end

      private

      def state_line(s)
        host = "#{s.lan ? "0.0.0.0" : "127.0.0.1"}:#{s.port}"
        line =
          case s.state
          when :listening then "listening on #{host}#{" · LAN, cleartext" if s.lan}"
          when :in_use then "#{host} in use"
          when :held then "another inbox#{" (pid #{s.held_by})" if s.held_by} is listening"
          when :failed then "#{host}: the listener failed"
          else "off: start with --listen or --listen-lan"
          end
        s.fixture ? "#{line} · fixture" : line
      end

      def listening_lines(s)
        urls = s.urls ? s.urls.map { |url| "  " + elide(url) } : ["  looking up this Mac's addresses…"]
        out = [""] + urls + ["", "  phone may use: #{s.allowed_modes.join(", ")}"]
        out << "  " + FIREWALL.fetch(s.firewall) if s.lan && s.firewall
        out
      end

      def elide(url) = url.sub(/(?<=#)(.{4}).+(.{4})\z/, "\\1…\\2")

      def advice(s, width)
        case s.state
        when :in_use then ["", "  trying again every few seconds; or pick another port with", "  --listen=PORT"]
        when :held then ["", "  this one takes over once that one quits"]
        when :failed then ["", *Text.wrap(s.error.to_s, width - 2).map { |l| "  " + l }, "", "  restart the inbox once that is fixed"]
        else ["", "  or set CLAUDE_INBOX_LISTEN=lan in your shell; the README's", "  \"Starting sessions from your phone\" has the rest"]
        end
      end

      def key_lines(s)
        return ["  paired phones get 401 until they pair again —", "  rotate? y/n"] if @asking
        (s.state == :listening) ? ["  c copy  r new token  esc close"] : ["  esc close"]
      end
    end
  end
end
