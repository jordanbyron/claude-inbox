# frozen_string_literal: true

require "unicode/display_width"

module ClaudeInbox
  # Width-aware string helpers. Never use String#[] on user-facing text:
  # session names carry emoji and glyphs that break byte/char slicing.
  module Text
    ANSI = /\e\[[0-9;?]*[A-Za-z]/
    # A grapheme, or an escape that takes no column.
    GLYPH = /#{ANSI}|\X/
    ELLIPSIS = "…"

    module_function

    def strip_ansi(s) = s.gsub(ANSI, "")

    # Bytes that aren't UTF-8 become U+FFFD.
    def utf8(s) = String.new(s.to_s, encoding: Encoding::UTF_8).scrub("\uFFFD")

    # Control characters as \xNN, so quoted text can't reach the terminal
    # as an escape.
    def printable(s) = utf8(s).gsub(/[[:cntrl:]]/) { |c| format("\\x%02x", c.ord) }

    def width(s) = Unicode::DisplayWidth.of(strip_ansi(s))

    # Truncate to `w` columns, appending an ellipsis when anything was cut.
    # Handles wide glyphs by stepping grapheme by grapheme.
    def truncate(s, w)
      return "" if w <= 0
      return s if width(s) <= w
      take(s, w - width(ELLIPSIS)) << ELLIPSIS
    end

    # First `n` columns, no ellipsis. Colors survive the cut, and a reset
    # closes whichever one the cut left open.
    def take(s, n)
      out = +""
      used = 0
      s.scan(GLYPH) do |g|
        gw = g.start_with?("\e") ? 0 : Unicode::DisplayWidth.of(g)
        break if used + gw > n
        out << g
        used += gw
      end
      (out.include?("\e") && !out.end_with?("\e[0m")) ? out << "\e[0m" : out
    end

    # Plain text with its first `n` columns removed.
    def drop(s, n)
      used = 0
      out = +""
      s.each_grapheme_cluster do |g|
        if used >= n
          out << g
        else
          used += Unicode::DisplayWidth.of(g)
        end
      end
      out
    end

    # Right-pad to exactly `w` columns. Truncates if too long.
    def pad(s, w)
      s = truncate(s, w)
      s + (" " * [w - width(s), 0].max)
    end

    # Greedy word wrap on display width. Words wider than `w` are split.
    def wrap(s, w)
      return [s.rstrip] if w <= 0 || width(s) <= w
      lines = []
      line = +""
      s.split(/(?<= )/).each do |word|
        if width(line) + width(word.rstrip) > w && !line.empty?
          lines << line
          line = +""
        end
        while width(word) > w
          head = take(word, w)
          lines << head
          word = word[head.size..]
        end
        line << word
      end
      lines << line unless line.empty?
      lines.map(&:rstrip)
    end

    # "45s", "12m", "3h", "2d"
    def age(seconds)
      s = seconds.to_i
      return "0s" if s <= 0
      return "#{s}s" if s < 60
      return "#{s / 60}m" if s < 3600
      return "#{s / 3600}h" if s < 86_400
      "#{s / 86_400}d"
    end
  end
end
