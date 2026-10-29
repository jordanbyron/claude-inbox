# frozen_string_literal: true

module ClaudeInbox
  # The eight colors `/color` offers, as the CLI maps them to a terminal
  # (docs/cli-quirks.md).
  module Palette
    ANSI = {
      "red" => 31, "green" => 32, "yellow" => 33,
      "blue" => 34, "purple" => 35, "cyan" => 36
    }.freeze

    INDEXED = {"orange" => 208, "pink" => 205}.freeze

    SEQUENCES = ANSI.transform_values { |n| "\e[#{n}m" }
      .merge(INDEXED.transform_values { |n| "\e[38;5;#{n}m" }).freeze

    # Default foreground, not a full reset: the label is often bold or
    # italic already, and \e[0m would strip that.
    RESET = "\e[39m"

    def self.paint(text, name)
      seq = SEQUENCES[name]
      seq ? seq + text + RESET : text
    end
  end
end
