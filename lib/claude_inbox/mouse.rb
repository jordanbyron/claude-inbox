# frozen_string_literal: true

module ClaudeInbox
  # Parses SGR mouse reports ("\e[<Cb;Cx;Cy(M|m)", emitted once App turns on
  # \e[?1003h\e[?1006h) into clicks, pointer moves and wheel ticks. Pure: no
  # terminal, no IO. Row and column are the terminal's own 1-based ones, so
  # callers can index straight into what they just painted.
  module Mouse
    SEQUENCE = /\e\[<(\d+);(\d+);(\d+)([Mm])/

    Event = Struct.new(:kind, :row, :col)

    # The read cut at its reports, in order: an Event per report acted on,
    # the keys between as strings. An ignored report still cuts, so the keys
    # either side of it never join into one.
    def self.split(raw)
      out = []
      rest = raw
      while (m = SEQUENCE.match(rest))
        out << m.pre_match unless m.pre_match.empty?
        cb, col, row, type = m.captures
        kind = kind_for(cb.to_i, type)
        out << Event.new(kind, row.to_i, col.to_i) if kind
        rest = m.post_match
      end
      out << rest unless rest.empty?
      out
    end

    # Bit 6 (0x40) marks a wheel tick, direction in bit 0. Otherwise bits
    # 0-1 give the button (0 = left, 3 = none) and bit 5 (0x20) marks motion,
    # so 0x23 masks both at once. Only a left click, released of any drag,
    # counts, and motion with no button held is the pointer moving; middle
    # and right buttons and drags are left for the terminal's own handling.
    def self.kind_for(cb, type)
      return (cb.even? ? :scroll_up : :scroll_down) if cb & 0x40 != 0
      return :move if cb & 0x23 == 0x23
      :click if type == "M" && cb & 0x23 == 0
    end
    private_class_method :kind_for
  end
end
