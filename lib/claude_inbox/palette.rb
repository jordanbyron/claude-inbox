# frozen_string_literal: true

module ClaudeInbox
  # The eight colors `/color` offers, mapped to the terminal the same way
  # Claude Code's own tmux code maps them when it tints a teammate pane:
  # six are plain ansi, and orange and pink have no ansi name so they go
  # through a 256-color index.
  #
  # Closing with 39 (default foreground) rather than 0 (reset everything)
  # matters: the label is often already bold or italic and a full reset
  # would strip that back off.
  class Palette
    ANSI = {
      "red" => 31, "green" => 32, "yellow" => 33,
      "blue" => 34, "purple" => 35, "cyan" => 36
    }.freeze

    INDEXED = {"orange" => 208, "pink" => 205}.freeze

    SEQUENCES = ANSI.transform_values { |n| "\e[#{n}m" }
      .merge(INDEXED.transform_values { |n| "\e[38;5;#{n}m" }).freeze

    RESET = "\e[39m"

    def initialize(enabled: true)
      @enabled = enabled
    end

    def paint(text, name)
      return text unless @enabled
      seq = SEQUENCES[name]
      seq ? seq + text + RESET : text
    end
  end
end
