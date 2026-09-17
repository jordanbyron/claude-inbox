# frozen_string_literal: true

module ClaudeInbox
  # The eight colours `/color` offers, mapped to the terminal the same way
  # Claude Code's own tmux code maps them when it tints a teammate pane:
  # six are plain ansi, and orange and pink have no ansi name so they go
  # through a 256-colour index.
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

    RESET = "\e[39m"

    def self.known?(name) = ANSI.key?(name) || INDEXED.key?(name)

    def self.sequence(name)
      return "\e[#{ANSI[name]}m" if ANSI.key?(name)
      return "\e[38;5;#{INDEXED[name]}m" if INDEXED.key?(name)
      nil
    end

    def initialize(enabled: true)
      @enabled = enabled
    end

    def paint(text, name)
      return text unless @enabled
      seq = self.class.sequence(name)
      seq ? seq + text + RESET : text
    end
  end
end
