# frozen_string_literal: true

require "tty-box"
require_relative "text"
require_relative "text_buffer"

module ClaudeInbox
  # A small box over the list that claims every key until it answers. Like
  # NewSessionForm, `press(name, raw)` says what happened: nil while the box
  # stays up, :cancel when it is dismissed, or the answer App acts on, with
  # the details read off the dialog afterwards. `frame(width)` is the box
  # Renderer overlays. Pure: nothing here touches the store or the client.
  class Dialog
    WIDTH = 44

    attr_reader :kind, :id

    def initialize(kind, id)
      @kind = kind
      @id = id
    end

    def frame(width, caret = nil)
      box = [width - 4, self.class::WIDTH].min
      TTY::Box.frame(lines(box - 4, caret).join("\n"), title: {top_left: title}, padding: [0, 1], width: box)
        .split("\n")
    end

    # `s` snooze: one key per choice, and the choice is read from `choice`.
    class Snooze < Dialog
      MENU = [
        ["1", "15 minutes", :m15],
        ["2", "1 hour", :h1],
        ["3", "tomorrow 9am", :tomorrow_9am],
        ["4", "until I wake it", :until_woken]
      ].freeze

      attr_reader :choice

      def initialize(id) = super(:snooze, id)

      def title = " Snooze "

      def lines(_width, _caret) = MENU.map { |k, label, _| "  #{k}  #{label}" } + ["", "  esc  cancel"]

      def press(name, key)
        return :cancel if name == :escape || key == "q"
        entry = MENU.find { |k, _, _| k == key }
        return nil unless entry
        @choice = entry[2]
        :snooze
      end
    end

    # `X` stop, `Ctrl-x` delete and Enter on a remote row all ask first and
    # all take `y`, but the words differ because the outcomes do: read the
    # box before answering.
    class Confirm < Dialog
      TITLES = {stop: " Stop ", delete: " Delete ", adopt: " Adopt "}.freeze

      def title = TITLES.fetch(kind)

      def lines(_width, _caret)
        case kind
        when :stop then ["  Stop session #{id}?", "", "  y  stop it", "  esc  cancel"]
        when :delete
          ["  Delete session #{id}?", "  Its worktree and conversation", "  go with it.",
            "", "  y  delete it", "  esc  keep it"]
        when :adopt
          ["  Pull this session into the daemon?", "  Its phone session ends and a",
            "  new one takes its place.", "", "  y  adopt it", "  esc  cancel"]
        end
      end

      def press(name, key)
        return :confirm if key == "y"
        return :cancel if name == :escape || key == "n" || key == "q"
        nil
      end
    end

    # `a` alias and `P` pull request: one line of text, read from `value`
    # once :save comes back. Empty means clear.
    class Prompt < Dialog
      TITLES = {alias: " Alias ", pr: " Pull request "}.freeze
      QUESTIONS = {alias: "  New alias:", pr: "  Pull request URL (empty clears):"}.freeze

      def initialize(kind, id, value)
        super(kind, id)
        @buffer = TextBuffer.new(value)
      end

      def value = @buffer.to_s

      def title = TITLES.fetch(kind)

      def lines(width, caret)
        [QUESTIONS.fetch(kind), "", "  > " + @buffer.row(width - 4, cursor: caret), "", "  ⏎ save · esc cancel"]
      end

      def press(name, key)
        case name
        when :escape then :cancel
        when :return, :enter then :save
        else
          @buffer.press(name, key)
          nil
        end
      end
    end

    # `N`: whether the listener is up, and how a phone reaches it.
    class Pairing < Dialog
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
        out += (s.state == :listening) ? listening_lines(s) : advice(s)
        if s.recent.any?
          out << "" << "  recent:"
          out += s.recent.reverse.map { |o| "    #{o.at.strftime("%H:%M")}  #{o.via}  #{o.result}" }
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

      def advice(s)
        case s.state
        when :in_use then ["", "  trying again every few seconds; or pick another port with", "  --listen=PORT"]
        when :held then ["", "  this one takes over once that one quits"]
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
