# frozen_string_literal: true

require_relative "text"

module ClaudeInbox
  # One editable string with a cursor in it. Every edit and all the cursor
  # arithmetic live here, so callers never index into the text themselves:
  # they hand over keypresses and ask for something to draw.
  #
  # Positions count cells, not bytes or characters. A cell is a grapheme
  # cluster — prompts and session names carry emoji, and character indexes
  # cut them in half — or a Chip, an attached image that shows as one
  # `[Image #1]` token and moves and deletes as one unit, the way Claude
  # Code's own prompt treats a pasted image.
  #
  #   b = TextBuffer.new("ab")
  #   b.press(:left, "\e[D")
  #   b.press("X", "X")
  #   b.to_s                    # => "aXb"
  class TextBuffer
    Chip = Struct.new(:n, :path) do
      def to_s = "[Image ##{n}]"
    end

    def initialize(text = "")
      @g = text.grapheme_clusters
      @cursor = @g.size
    end

    def to_s = @g.join

    def empty? = @g.empty?

    # Grapheme offset of the cursor. Rendering goes through #row / #view;
    # this is here for callers that need to reason about position (tests).
    attr_reader :cursor

    def chips = @g.grep(Chip)

    def expand = @g.map { |c| c.is_a?(Chip) ? yield(c) : c }.join

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

    # Numbered after the chips already in the text, so a second image is
    # `[Image #2]` even after the first was deleted, as Claude Code does.
    def attach(path)
      chip = Chip.new(@next_chip = (@next_chip || 0) + 1, path)
      @g.insert(@cursor, chip)
      @cursor += 1
      chip
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
      first += 1 while width_of(@g[first...@cursor]) > width - 1
      cells = []
      @g[first..].each do |c|
        break if width_of(cells) + width_of([c]) > width
        cells << c
      end
      paint(cells, @cursor - first, cursor)
    end

    # The visible slice of a multi-line editor: word-wrapped to `width`, at
    # most `height` rows, plus how many rows are hidden above them. Shows the
    # end of the text, which is where typing happens; walk the cursor up out
    # of that window and the window follows it instead. `chip` paints each
    # attached image's token; without it they read as plain text.
    def view(width, height, cursor: nil, chip: nil)
      rows = wrapped(width)
      at = cursor_row(rows)
      first = [rows.size - height, 0].max
      first = at if at < first
      slice = rows[first, height]
      lines = slice.map { |cells, _| paint(cells, nil, nil, chip) }
      if cursor
        cells, start = slice[at - first]
        lines[at - first] = paint(cells, @cursor - start, cursor, chip)
      end
      [lines, first]
    end

    private

    def width_of(cells) = cells.sum { |c| Text.width(c.to_s) }

    def paint(cells, offset, cursor, chip = nil)
      out = cells.each_with_index.map do |c, i|
        s = c.to_s
        s = chip.call(s) if chip && c.is_a?(Chip)
        (i == offset) ? cursor.call(s) : s
      end
      out << cursor.call(" ") if offset && offset >= cells.size
      out.join
    end

    # One entry per display row: [cells, offset of its first cell]. A
    # cursor at the end of a row that is already full has no cell of its
    # own, so it gets a row of its own — what a terminal does when text
    # reaches the right margin.
    def wrapped(width)
      rows = logical_lines.flat_map do |line, start|
        at = start
        (line.empty? ? [[]] : segments(line, width)).map do |seg|
          row = [seg, at]
          at += seg.size
          row
        end
      end
      rows << [[], @g.size] if @cursor == @g.size && width_of(rows.last.first) >= width
      rows
    end

    # Text.wrap on cells, keeping the trailing spaces the cursor may sit on:
    # a chip is one cell however wide its label, so the wrap has to measure
    # cells rather than a joined string.
    def segments(cells, width)
      return [cells] if width_of(cells) <= width
      words = cells.slice_when { |c, _| c == " " }.to_a
      lines = []
      line = []
      words.each do |word|
        if !line.empty? && width_of(line) + width_of(word.reverse.drop_while { |c| c == " " }) > width
          lines << line
          line = []
        end
        while width_of(word) > width
          cut = word.size - 1
          cut -= 1 while cut > 0 && width_of(word[0...cut]) > width
          lines << word[0...cut]
          word = word[cut..]
        end
        line += word
      end
      lines << line unless line.empty?
      lines
    end

    # The newline itself belongs to the line it ends, so a cursor sitting on
    # it lands past the end of that line rather than at the start of the next.
    def logical_lines
      out = []
      start = 0
      line = []
      @g.each_with_index do |g, i|
        next line << g unless g == "\n"
        out << [line, start]
        line = []
        start = i + 1
      end
      out << [line, start]
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
