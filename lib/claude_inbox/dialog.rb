# frozen_string_literal: true

require "tty-box"
require_relative "text"
require_relative "text_buffer"
require_relative "theme"

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
      @theme = Theme.new
    end

    def frame(width, caret = nil)
      box = [width - 4, fit].min
      TTY::Box.frame(lines(box - 4, caret).join("\n"), title: {top_left: title}, padding: [0, 1], width: box)
        .split("\n")
    end

    # How wide the box wants to be; the frame caps it at the terminal.
    def fit = self.class::WIDTH

    private

    def key(name) = @theme.cyan_bold(name)

    # A key and what it does.
    def hint(name, action) = "#{key(name)}  #{@theme.dim(action)}"

    # `s` snooze: one key per choice, and the choice is read from `choice`.
    class Snooze < Dialog
      MENU = [
        ["1", "15 minutes", :m15],
        ["2", "1 hour", :h1],
        ["3", "tomorrow 9am", :tomorrow_9am],
        ["4", "until I wake it", :until_woken],
        ["5", "custom", :custom]
      ].freeze

      attr_reader :choice

      def initialize(id) = super(:snooze, id)

      def title = " Snooze "

      def lines(_width, _caret) = MENU.map { |k, label, _| "  #{key(k)}  #{label}" } + ["", "  " + hint("esc", "cancel")]

      def press(name, key)
        return :cancel if name == :escape || key == "q"
        entry = MENU.assoc(key)
        return nil unless entry
        @choice = entry[2]
        :snooze
      end
    end

    # `o` open and `y` copy on a session with several PRs: the headline
    # first, and the same key again takes it. The PR is read from `choice`.
    class PrPicker < Dialog
      MARGIN = 6
      KEYS = {open: "o", copy: "y"}.freeze

      attr_reader :choice

      def initialize(kind, session)
        super(kind, session.key)
        @prs = [session.pr, *session.prs.reject { |pr| pr.equal?(session.pr) }].first(9)
      end

      def title = " #{kind.to_s.capitalize} pull request "

      # Titles vary, so the box grows to the longest line plus some air,
      # and never shrinks below a plain dialog.
      def fit = [WIDTH, lines(Float::INFINITY, nil).map { |l| Text.width(l) }.max + MARGIN].max

      def lines(width, _caret)
        (@prs.each_with_index.map { |pr, i| "  #{key((i + 1).to_s)}  #{label(pr)}" } +
          ["", "  #{hint(KEYS.fetch(kind), "#{kind} #{@prs.first.short}")} · #{key("esc")} #{@theme.dim("cancel")}"])
          .map { |line| Text.truncate(line, width) }
      end

      def press(name, key)
        return :cancel if name == :escape || key == "q"
        @choice = @prs.first if key == KEYS.fetch(kind) || name == :return || name == :enter
        @choice = @prs[key.to_i - 1] if key.to_s.match?(/\A[1-9]\z/)
        @choice && :pick
      end

      private

      # The list's badge, then the title. A bare #190 is ambiguous only
      # once the list spans repos.
      def label(pr)
        name = (@prs.map(&:repo).uniq.size > 1) ? pr.qualified : pr.short
        pr.title ? @theme.pr_badge(pr, name) + @theme.dim(" · ") + pr.title : @theme.pr_badge(pr, name)
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
        when :stop then ["  Stop session #{id}?", "", "  " + hint("y", "stop it"), "  " + hint("esc", "cancel")]
        when :delete
          ["  Delete session #{id}?", "  Its worktree and conversation", "  go with it.",
            "", "  " + hint("y", "delete it"), "  " + hint("esc", "keep it")]
        when :adopt
          ["  Pull this session into the daemon?", "  Its phone session ends and a",
            "  new one takes its place.", "", "  " + hint("y", "adopt it"), "  " + hint("esc", "cancel")]
        end
      end

      def press(name, key)
        return :confirm if key == "y"
        return :cancel if name == :escape || key == "n" || key == "q"
        nil
      end
    end

    # The first launch without the Claude Code pane asks once whether to add
    # it, and has to say what the pane is to someone who has never seen it.
    class PaneOffer < Confirm
      WIDTH = 60
      SKETCH = [
        "  ┌──────────────────────────┬─────────────────────┐",
        "  │ > fix the flaky spec     │ 📥 Inbox            │",
        "  │                          │ ● needs you   docs  │",
        "  │ Reading app.rb…          │ ⠋ working     api   │",
        "  │                          │ ✓ done        auth  │",
        "  └──────────────────────────┴─────────────────────┘"
      ].freeze

      def initialize = super(:install, nil)

      def title = " ✨ The inbox, inside Claude Code "

      # Drawn by hand: TTY::Box measures an emoji as one column, which
      # pushes the right border out on every line that has one.
      def frame(width, _caret = nil)
        inner = [width - 4, WIDTH].min - 2
        ["┌#{title}#{"─" * (inner - Text.width(title))}┐",
          *lines(inner, nil).map { |l| "│#{Text.pad(Text.truncate(l, inner), inner)}│" },
          "└#{"─" * inner}┘"]
      end

      def lines(_width, _caret)
        ["", *SKETCH, "",
          "  • Every session, docked beside the transcript",
          "  • Switch sessions without leaving the one you're in",
          "  • Snooze, pin and settle with the same keys",
          "  • /inbox opens it, ctrl+x tab focuses it",
          "",
          "  You can install this later with claude-inbox install",
          "",
          "      #{hint("y", "add it to Claude Code")}      #{hint("esc", "not now")}"]
      end
    end

    # `a` alias, `P` pull request and `s` `5` snooze: one line of text, read
    # from `value` once :save comes back. Empty means clear.
    class Prompt < Dialog
      TITLES = {alias: " Alias ", pr: " Pull request ", snooze: " Snooze "}.freeze
      QUESTIONS = {alias: "  New alias:", pr: "  Pull request URL (empty clears):",
                   snooze: "  Wake at (2h, 5pm, fri, tonight):"}.freeze

      def initialize(kind, id, value)
        super(kind, id)
        @buffer = TextBuffer.new(value)
      end

      def value = @buffer.to_s

      def title = TITLES.fetch(kind)

      def lines(width, caret)
        [QUESTIONS.fetch(kind), "", "  > " + @buffer.row(width - 4, cursor: caret), "",
          "  #{key("⏎")} #{@theme.dim("save")} · #{key("esc")} #{@theme.dim("cancel")}"]
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
  end
end
