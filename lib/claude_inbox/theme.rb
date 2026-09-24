# frozen_string_literal: true

module ClaudeInbox
  # Chrome hues tuned to Atom One Dark rather than the terminal profile's
  # own ANSI reds and greens. 256-color indices, since those render the
  # same everywhere a terminal claims 256-color support.
  class Theme
    HUES = {red: 203, green: 108, yellow: 179, blue: 75, purple: 176, cyan: 73}.freeze
    BG = 236

    HUES.each_key do |hue|
      define_method(hue) { |text| color(text, hue) }
      define_method(:"#{hue}_bold") { |text| color(text, hue, bold: true) }
    end

    def initialize(enabled: true)
      @enabled = enabled
    end

    # A filled pill: editor-background text on the hue, for a selected row
    # or choice — the inverse of `color`, which puts the hue on the text.
    def pill(text, hue)
      return text unless @enabled
      "\e[38;5;#{BG};48;5;#{HUES.fetch(hue)}m#{text}\e[0m"
    end

    private

    def color(text, hue, bold: false)
      return text unless @enabled
      codes = ["38;5;#{HUES.fetch(hue)}"]
      codes << "1" if bold
      "\e[#{codes.join(";")}m#{text}\e[0m"
    end
  end
end
