# frozen_string_literal: true

module ClaudeInbox
  # Parses SGR mouse reports ("\e[<Cb;Cx;Cy(M|m)", emitted once App turns on
  # \e[?1000h\e[?1006h) into clicks and wheel ticks. Pure: no terminal, no
  # IO. Row/col are the terminal's own 1-based coordinates, so callers can
  # index straight into what they just painted.
  module Mouse
    SEQUENCE = /\e\[<(\d+);(\d+);(\d+)([Mm])/

    Event = Struct.new(:kind, :row, :col)

    # A raw keypress can glue several reports together the same way a fast
    # "esc :q" glues onto one read (see App#split_keys), so this scans
    # rather than matching once.
    def self.events(raw)
      raw.to_s.scan(SEQUENCE).filter_map do |cb, col, row, type|
        kind = kind_for(cb.to_i, type)
        Event.new(kind, row.to_i, col.to_i) if kind
      end
    end

    # Bit 6 (0x40) marks a wheel tick, direction in bit 0. Otherwise this is
    # a button press/release: bits 0-1 give the button (0 = left) and bit 5
    # (0x20) marks a drag, so 0x23 masks both at once. Only a left click,
    # released of any drag, counts; middle/right buttons and drags are left
    # for the terminal's own handling.
    def self.kind_for(cb, type)
      return (cb.even? ? :scroll_up : :scroll_down) if cb & 0x40 != 0
      :click if type == "M" && cb & 0x23 == 0
    end
    private_class_method :kind_for
  end
end
