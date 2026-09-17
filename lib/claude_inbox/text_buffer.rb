# frozen_string_literal: true

require_relative "text"

module ClaudeInbox
  # One editable string with a cursor in it. Every edit and all the cursor
  # arithmetic live here, so callers never index into the text themselves:
  # they hand over keypresses and ask for something to draw.
  #
  # Positions count grapheme clusters, not bytes or characters — prompts and
  # session names carry emoji, and character indexes cut them in half.
  #
  #   b = TextBuffer.new("ab")
  #   b.press(:left, "\e[D")
  #   b.press("X", "X")
  #   b.to_s                    # => "aXb"
  class TextBuffer
    def initialize(text = "")
      @g = text.grapheme_clusters
      @cursor = @g.size
    end

    def to_s = @g.join

    def empty? = @g.empty?

    # Grapheme offset of the cursor. Rendering goes through #row / #view;
    # this is here for callers that need to reason about position (tests).
    attr_reader :cursor

    # Swaps the whole text out and parks the cursor at the end — what
    # completion wants after it extends a path.
    def replace(text)
      @g = text.grapheme_clusters
      @cursor = @g.size
      self
    end

    # Everything before the cursor, as one string.
    def head = @g[0...@cursor].join

    # How completion drops a picked command in over the half-typed one.
    def replace_before(count, text)
      delete(@cursor - count, count)
      insert(text)
    end

    def insert(text)
      g = text.grapheme_clusters
      @g.insert(@cursor, *g)
      @cursor += g.size
    end

    # Handles one keypress — readline's editing keys, plus printable text —
    # or returns false when the key is not ours and the caller should deal
    # with it (Tab, Enter, Escape, anything else unprintable).
    def press(name, raw)
      case name
      when :left then @cursor = [@cursor - 1, 0].max
      when :right then @cursor = [@cursor + 1, @g.size].min
      when :home, :ctrl_a then @cursor = 0
      when :end, :ctrl_e then @cursor = @g.size
      when :backspace, :ctrl_h then delete(@cursor - 1, 1)
      when :delete then delete(@cursor, 1)
      when :ctrl_u then delete(0, @cursor)
      when :ctrl_k then delete(@cursor, @g.size - @cursor)
      when :ctrl_w then delete_word
      else
        return false unless raw.is_a?(String) && raw.match?(/\A[[:print:]]+\z/)
        insert(raw)
      end
      true
    end

    # The text as a single row of at most `width` columns, scrolled right so
    # that the cursor stays in view on a value longer than the box. `cursor`
    # paints the one cell under it; pass nil for an unfocused field, which
    # gets plain truncated text instead.
    def row(width, cursor: nil)
      return Text.truncate(to_s, width) unless cursor
      first = 0
      first += 1 while Text.width(@g[first...@cursor].join) > width - 1
      paint(Text.take(@g[first..].join, width), @cursor - first, cursor)
    end

    # The visible slice of a multi-line editor: word-wrapped to `width`, at
    # most `height` rows, plus how many rows are hidden above them. Shows the
    # end of the text, which is where typing happens; walk the cursor up out
    # of that window and the window follows it instead.
    def view(width, height, cursor: nil)
      rows = wrapped(width)
      at = cursor_row(rows)
      first = [rows.size - height, 0].max
      first = at if at < first
      slice = rows[first, height]
      lines = slice.map(&:first)
      if cursor
        text, start = slice[at - first]
        lines[at - first] = paint(text, @cursor - start, cursor)
      end
      [lines, first]
    end

    private

    # Splits `text` at `offset` and marks the cell the cursor sits on, using
    # a space when that is one past the end.
    def paint(text, offset, cursor)
      g = text.grapheme_clusters
      g[0...offset].join + cursor.call(g[offset] || " ") + (g[(offset + 1)..] || []).join
    end

    # One entry per display row: [text, grapheme offset of its first cell].
    # A cursor at the end of a row that is already full has no cell of its
    # own, so it gets a row of its own — what a terminal does when text
    # reaches the right margin.
    def wrapped(width)
      rows = logical_lines.flat_map do |line, start|
        at = start
        (line.empty? ? [""] : Text.segments(line, width)).map do |seg|
          row = [seg, at]
          at += seg.grapheme_clusters.size
          row
        end
      end
      rows << ["", @g.size] if @cursor == @g.size && Text.width(rows.last.first) >= width
      rows
    end

    # The newline itself belongs to the line it ends, so a cursor sitting on
    # it lands past the end of that line rather than at the start of the next.
    def logical_lines
      out = []
      start = 0
      line = []
      @g.each_with_index do |g, i|
        next line << g unless g == "\n"
        out << [line.join, start]
        line = []
        start = i + 1
      end
      out << [line.join, start]
    end

    def cursor_row(rows) = rows.rindex { |_, start| start <= @cursor } || 0

    def delete(at, length)
      return if at < 0 || length <= 0
      @g.slice!(at, length)
      @cursor = at
    end

    # Back over any spaces, then over the word itself.
    def delete_word
      at = @cursor
      at -= 1 while at > 0 && @g[at - 1] == " "
      at -= 1 while at > 0 && @g[at - 1] != " "
      delete(at, @cursor - at)
    end
  end
end
