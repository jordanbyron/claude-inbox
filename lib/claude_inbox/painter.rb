# frozen_string_literal: true

require "tty-cursor"

module ClaudeInbox
  # Diffs successive frames and writes only changed rows. No erase-to-end-of-
  # line after a row: in the terminal's last column the cursor stays put
  # (pending wrap), so EL would eat the glyph just drawn.
  class Painter
    def initialize(out, cursor: TTY::Cursor)
      @out = out
      @cursor = cursor
      @prev = []
    end

    def paint(lines)
      buf = +""
      lines.each_with_index do |line, i|
        next if @prev[i] == line
        buf << @cursor.move_to(0, i) << line
      end
      if @prev.size > lines.size
        (lines.size...@prev.size).each { |i| buf << @cursor.move_to(0, i) << @cursor.clear_line }
      end
      @out.print buf unless buf.empty?
      @out.flush
      @prev = lines
    end

    def invalidate = @prev = []
  end
end
