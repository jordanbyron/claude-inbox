# frozen_string_literal: true

require "tty-box"

module ClaudeInbox
  # A small box over the list that claims every key until it answers. Like
  # NewSessionForm, `press(name, raw)` says what happened: nil while the box
  # stays up, :cancel when it is dismissed, or the answer App acts on, with
  # the details read off the dialog afterwards. `frame(width)` is the box
  # Renderer overlays. Pure: nothing here touches the store or the client.
  class Dialog
    attr_reader :kind, :id

    def initialize(kind, id)
      @kind = kind
      @id = id
    end

    def frame(width)
      TTY::Box.frame(lines.join("\n"), title: {top_left: title}, padding: [0, 1], width: [width - 4, 44].min)
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

      def lines = MENU.map { |k, label, _| "  #{k}  #{label}" } + ["", "  esc  cancel"]

      def press(name, key)
        return :cancel if name == :escape || key == "q"
        entry = MENU.find { |k, _, _| k == key }
        return nil unless entry
        @choice = entry[2]
        :snooze
      end
    end

    # `X` stop and `Ctrl-x` delete both ask first and both take `y`, but the
    # words differ because the outcomes do: read the box before answering.
    class Confirm < Dialog
      TITLES = {stop: " Stop ", delete: " Delete "}.freeze

      def title = TITLES.fetch(kind)

      def lines
        case kind
        when :stop then ["  Stop session #{id}?", "", "  y  stop it", "  esc  cancel"]
        when :delete
          ["  Delete session #{id}?", "  Its worktree and conversation", "  go with it.",
            "", "  y  delete it", "  esc  keep it"]
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

      attr_reader :value

      def initialize(kind, id, value)
        super(kind, id)
        @value = +value
      end

      def title = TITLES.fetch(kind)

      def lines = [QUESTIONS.fetch(kind), "", "  > #{value}_", "", "  ⏎ save · esc cancel"]

      def press(name, key)
        case name
        when :escape then :cancel
        when :return, :enter then :save
        when :backspace, :ctrl_h
          @value = @value[0...-1]
          nil
        else
          @value << key if key.is_a?(String) && key.match?(/\A[[:print:]]\z/)
          nil
        end
      end
    end

    # The short form of README's key table: chords and Ctrl variants are
    # left out when the base key says enough.
    class Help < Dialog
      KEYS = [
        ["j k", "move"], ["gg G", "first / last"],
        ["^d ^u", "half page"], ["⇥ ⇧⇥", "section"],
        ["⏎ l", "attach / expand"], ["h", "close peek/fold"],
        ["za zo zc", "fold"], ["p", "peek pane"],
        ["J K", "scroll peek"], ["n", "new session"],
        ["t", "pin"], ["s", "snooze"],
        ["u", "wake"], ["x", "settle"],
        ["a", "alias"], ["o", "open PR"],
        ["P", "link PR"], ["X", "stop"],
        ["^x", "delete"], ["/", "filter"],
        ["R", "poll now"], [":", "command"],
        ["q", "quit"], ["?", "this"]
      ].freeze

      COLUMN = 26

      def initialize = super(:help, nil)

      def title = " Keys "

      def lines
        KEYS.each_slice(2).map { |cells| cells.map { |k, d| "  #{k.ljust(9)}#{d}".ljust(COLUMN) }.join.rstrip }
      end

      def frame(width)
        TTY::Box.frame(lines.join("\n"), title: {top_left: title}, padding: [0, 1], width: [width - 4, COLUMN * 2 + 4].min)
          .split("\n")
      end

      def press(name, key)
        return :cancel if name == :escape || key == "q" || key == "?"
        nil
      end
    end
  end
end
