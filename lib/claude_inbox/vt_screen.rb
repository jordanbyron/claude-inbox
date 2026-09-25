# frozen_string_literal: true

require "strscan"
require "unicode/display_width"

module ClaudeInbox
  # A deliberately small cursor-addressed screen model. `claude logs` emits a
  # replay of the session's terminal output — cursor moves, erase-line, SGR —
  # not plain text, and words are often separated by cursor motion instead of
  # spaces. Stripping escapes therefore yields garbage; feeding them through a
  # grid does not. This is not a VT emulator: it handles the handful of
  # sequences the replay actually uses and ignores the rest.
  class VtScreen
    CSI = /\e\[([0-9;?]*)([A-Za-z@`])/
    OSC = /\e\][^\a\e]*(?:\a|\e\\)?/
    ESC_OTHER = /\e[()#][A-Za-z0-9]|\e[A-Za-z0-9=>78]/

    def initialize(rows: 300, cols: 300)
      @rows = rows
      @cols = cols
      @grid = Array.new(rows) { Array.new(cols) { " " } }
      @row = 0
      @col = 0
    end

    def feed(str)
      ss = StringScanner.new(str.dup.force_encoding("UTF-8").scrub)
      until ss.eos?
        if ss.scan(CSI)
          csi(ss[1], ss[2])
        elsif ss.scan(OSC) || ss.scan(ESC_OTHER)
          next
        else
          ch = ss.getch
          control(ch) || put(ch)
        end
      end
      self
    end

    # Text rows with trailing whitespace removed; leading/trailing blank rows
    # dropped and runs of blank rows collapsed to one.
    def lines
      out = @grid.map { |r| r.join.rstrip }
      out.shift while out.first&.empty?
      out.pop while out.last&.empty?
      out.chunk_while { |a, b| a.empty? && b.empty? }.map(&:first)
    end

    private

    def control(ch)
      case ch
      when "\r" then @col = 0
      when "\n" then newline
      when "\b" then @col = [@col - 1, 0].max
      when "\t" then @col = [((@col / 8) + 1) * 8, @cols - 1].min
      when "\a", "\0", "\e" then nil
      else return false
      end
      true
    end

    def newline
      if @row >= @rows - 1
        @grid.shift
        @grid << Array.new(@cols) { " " }
      else
        @row += 1
      end
    end

    def put(ch)
      o = ch.ord
      return if o < 32
      w = (o < 127) ? 1 : Unicode::DisplayWidth.of(ch)
      return if w <= 0
      if @col + w > @cols
        @col = 0
        newline
      end
      @grid[@row][@col] = ch
      @grid[@row][@col + 1] = "" if w == 2 && @col + 1 < @cols
      @col += w
    end

    def csi(params, final)
      return if params.start_with?("?")
      nums = params.split(";").map { |x| x.empty? ? nil : x.to_i }
      n = nums[0] || 1
      case final
      when "H", "f"
        @row = (n - 1).clamp(0, @rows - 1)
        @col = ((nums[1] || 1) - 1).clamp(0, @cols - 1)
      when "A" then @row = [@row - n, 0].max
      when "B" then @row = [@row + n, @rows - 1].min
      when "C" then @col = [@col + n, @cols - 1].min
      when "D" then @col = [@col - n, 0].max
      when "G", "`" then @col = (n - 1).clamp(0, @cols - 1)
      when "d" then @row = (n - 1).clamp(0, @rows - 1)
      when "E"
        @row = [@row + n, @rows - 1].min
        @col = 0
      when "F"
        @row = [@row - n, 0].max
        @col = 0
      when "J" then erase_display(nums[0] || 0)
      when "K" then erase_line(nums[0] || 0)
      when "@" then n.times { @grid[@row].insert(@col, " ") && @grid[@row].pop }
      when "P" then n.times { @grid[@row].delete_at(@col) && @grid[@row].push(" ") }
      when "X" then n.times { |k| @grid[@row][@col + k] = " " if @col + k < @cols }
      end
    end

    def erase_display(mode)
      case mode
      when 0
        erase_line(0)
        ((@row + 1)...@rows).each { |r| @grid[r].fill(" ") }
      when 1
        erase_line(1)
        (0...@row).each { |r| @grid[r].fill(" ") }
      else
        @grid.each { |r| r.fill(" ") }
      end
    end

    def erase_line(mode)
      case mode
      when 0 then @grid[@row].fill(" ", @col)
      when 1 then @grid[@row].fill(" ", 0, @col + 1)
      else @grid[@row].fill(" ")
      end
    end
  end
end
