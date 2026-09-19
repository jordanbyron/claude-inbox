# frozen_string_literal: true

module ClaudeInbox
  # Chrome hues tuned to Atom One Dark rather than the terminal profile's
  # own ANSI reds and greens. 256-color indices, since those render the
  # same everywhere a terminal claims 256-color support.
  class Theme
    HUES = {red: 204, green: 114, yellow: 180, blue: 75, purple: 176, cyan: 73}.freeze

    def initialize(enabled: true)
      @enabled = enabled
      HUES.each_key do |hue|
        define_singleton_method(hue) { |text| color(text, hue) }
        define_singleton_method(:"#{hue}_bold") { |text| color(text, hue, bold: true) }
      end
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
