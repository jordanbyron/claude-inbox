# frozen_string_literal: true

module ClaudeInbox
  # Chrome hues tuned to Atom One Dark rather than the terminal profile's
  # own ANSI reds and greens. 256-color indices, since those render the
  # same everywhere a terminal claims 256-color support.
  class Theme
    HUES = {red: 203, green: 108, yellow: 179, blue: 75, purple: 176, cyan: 73}.freeze
    BG = 236

    # GitHub's colors. A draft has no hue, so it dims; a state missing from
    # the table isn't named on the badge at all.
    PR_HUES = {"OPEN" => :green, "DRAFT" => nil, "MERGED" => :purple, "CLOSED" => :red}.freeze

    # The hue of PR_TROUBLE after a badge. Red for what puts the row in
    # Needs You; a conflict dims, since it waits on a rebase, not on you.
    PR_TROUBLE_HUES = {"FAILING" => :red, "CHANGES_REQUESTED" => :red}.freeze

    HUES.each_key do |hue|
      define_method(hue) { |text| color(text, hue) }
      define_method(:"#{hue}_bold") { |text| color(text, hue, bold: true) }
    end

    def dim(text) = "\e[2m#{text}\e[0m"

    # The hue, or dim when there is none.
    def tint(hue, text) = hue ? public_send(hue, text) : dim(text)

    # "#885 open", or "#885 open · ✗ checks" when something is wrong.
    # `name` replaces the bare number where that would be ambiguous.
    def pr_badge(pr, name = pr.short)
      return dim(name) unless PR_HUES.key?(pr.state)
      badge = tint(PR_HUES[pr.state], "#{name} #{pr.state.downcase}")
      pr.trouble ? badge + dim(" · ") + tint(PR_TROUBLE_HUES[pr.health], pr.trouble) : badge
    end

    # A filled pill: editor-background text on the hue, for a selected row
    # or choice — the inverse of `color`, which puts the hue on the text.
    def pill(text, hue) = "\e[38;5;#{BG};48;5;#{HUES.fetch(hue)}m#{text}\e[0m"

    private

    def color(text, hue, bold: false)
      codes = ["38;5;#{HUES.fetch(hue)}"]
      codes << "1" if bold
      "\e[#{codes.join(";")}m#{text}\e[0m"
    end
  end
end
