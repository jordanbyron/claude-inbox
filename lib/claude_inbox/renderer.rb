# frozen_string_literal: true

require "pastel"
require "tty-cursor"
require_relative "text"
require_relative "store"

module ClaudeInbox
  # sections -> Array<String> (one entry per terminal row, each exactly
  # `width` columns wide) plus a parallel Array of selectable items.
  # Pure: no terminal, no IO, no clock beyond the `now` it is handed.
  class Renderer
    Item = Struct.new(:kind, :row) do
      def id = row&.id

      def key = (kind == :settled_toggle) ? :settled : id
    end

    Frame = Struct.new(:lines, :items, :top)

    SECTION_TITLES = {
      needs_you: "Needs you",
      working: "Working",
      snoozed: "Snoozed",
      settled: "Settled"
    }.freeze

    GLYPH = {
      "blocked" => "✽", "failed" => "✗", "working" => "✻",
      "done" => "∙", "stopped" => "∙"
    }.freeze

    HELP = "↑↓ move · ⏎ attach · s snooze · u wake · a alias · x stop · ⇥ peek · / filter · q quit"

    def initialize(color: true, min_left: 44)
      @p = Pastel.new(enabled: color)
      @min_left = min_left
    end

    # opts: selected (id | :settled | nil), settled_expanded, top (scroll),
    #       peek (Array<String> | nil), peek_title, modal (Array<String> | nil),
    #       status (String), now (Time), filter (String | nil)
    def frame(sections, width:, height:, now:, **opts)
      selected = opts[:selected]
      body, items = body_lines(sections, width_for_list(width, opts[:peek]), selected, opts, now)

      view_h = height - 2 # header + footer
      top = clamp_top(opts[:top] || 0, body.size, view_h, items, selected)
      visible = body[top, view_h] || []
      visible_items = items[top, view_h] || []
      visible += [""] * (view_h - visible.size)
      visible_items += [nil] * (view_h - visible_items.size)

      list_w = width_for_list(width, opts[:peek])
      if opts[:peek]
        peek_lines = peek_pane(opts[:peek], opts[:peek_title], width - list_w - 1, view_h)
        visible = visible.each_with_index.map do |l, i|
          Text.pad(l, list_w) + @p.dim("│") + Text.pad(peek_lines[i] || "", width - list_w - 1)
        end
      end

      lines = [header(sections, width, opts[:status], now)] + visible.map { |l| Text.pad(l, width) } + [footer(width, opts)]
      lines = overlay(lines, opts[:modal], width) if opts[:modal]
      Frame.new(lines, [nil] + visible_items + [nil], top)
    end

    private

    def width_for_list(width, peek)
      return width unless peek
      [(width * 0.4).floor, @min_left].max.clamp(0, width)
    end

    def clamp_top(top, size, view_h, items, selected)
      idx = items.index { |item| item && item.key == selected }
      top = idx if idx && idx < top
      top = idx - view_h + 1 if idx && idx >= top + view_h
      top.clamp(0, [size - view_h, 0].max)
    end

    def header(sections, width, status, now)
      total = sections.all.size
      needs = sections.needs_you.size
      left = @p.bold(" claude-inbox") + @p.dim("  #{total} sessions")
      left += @p.red("  #{needs} need#{"s" if needs == 1} you") if needs > 0
      right = status ? @p.dim(status + " ") : ""
      Text.pad(left, width - Text.width(right)) + right
    end

    def footer(width, opts)
      text =
        if opts[:command] then " :#{opts[:command]}"
        elsif opts[:filter] then " /#{opts[:filter]}"
        else " #{opts[:help] || HELP}"
        end
      Text.pad(@p.dim(text), width)
    end

    def body_lines(sections, width, selected, opts, now)
      lines = []
      items = []
      sections.each_section do |name, rows|
        next if rows.empty?
        lines << "" << section_title(name, rows.size, width)
        items << nil << nil
        if name == :settled && !opts[:settled_expanded]
          lines << settled_toggle(rows.size, selected, width)
          items << Item.new(:settled_toggle, nil)
          next
        end
        rows.each do |row|
          row_lines(row, name, selected, width, now).each_with_index do |l, i|
            lines << l
            items << ((i.zero? && row.selectable?) ? Item.new(:row, row) : nil)
          end
        end
      end
      [lines, items]
    end

    def section_title(name, count, width)
      Text.pad(@p.bold(" #{SECTION_TITLES[name]}") + @p.dim(" #{count}"), width)
    end

    def settled_toggle(count, selected, width)
      marker = (selected == :settled) ? @p.cyan("▶") : " "
      Text.pad(" #{marker} " + @p.dim("… #{count} settled"), width)
    end

    def row_lines(row, section, selected, width, now)
      s = row.session
      sel = row.selectable? && selected == row.id
      marker = sel ? @p.cyan("▶") : " "
      glyph = glyph_for(s, section)
      project = @p.dim(s.project)
      meta = meta_for(row, section, now)

      # marker(1) + spaces + glyph + gap + label + gap + meta + gap + project
      fixed = 1 + 2 + 1 + 1 + 2 + Text.width(meta) + 2 + Text.width(project)
      label_w = [width - fixed, 8].max
      label = Text.truncate(row.label, label_w)
      label = if s.interactive? || section == :settled
        @p.dim(label)
      elsif sel
        @p.bold(label)
      else
        label
      end
      first = " #{marker} #{glyph} " + Text.pad(label, label_w) + "  " + meta + "  " + project

      return [Text.pad(first, width)] unless %i[needs_you working].include?(section) && !s.interactive?

      detail = @p.dim("      #{s.cwd}")
      [Text.pad(first, width), Text.pad(detail, width)]
    end

    def glyph_for(s, section)
      return @p.dim("○") if s.interactive?
      return @p.dim("z") if section == :snoozed
      g = GLYPH.fetch(s.state, "?")
      case s.state
      when "blocked" then @p.red(g)
      when "failed" then @p.red(g)
      when "working" then @p.yellow(g)
      when "done" then @p.green(g)
      else @p.dim(g)
      end
    end

    def meta_for(row, section, now)
      s = row.session
      case section
      when :snoozed
        return @p.dim("parked") if row.parked?
        @p.dim("wakes in #{Text.age(row.wake_at.to_i - now.to_i)}")
      when :settled
        @p.dim("#{s.state} #{Text.age(now.to_i - row.state_since.to_i)}")
      else
        return @p.dim("#{s.status || "interactive"} · #{Text.age(now - s.started_at)}") if s.interactive?
        parts = []
        parts << state_word(s)
        parts << s.waiting_for if s.waiting_for
        parts << Text.age(now.to_i - row.state_since.to_i) if row.state_since
        @p.dim(parts.join(" · "))
      end
    end

    def state_word(s)
      case s.state
      when "blocked" then @p.red("needs you")
      when "failed" then @p.red("failed")
      when "working" then (s.status == "waiting") ? "waiting" : "working"
      else s.state
      end
    end

    def peek_pane(lines, title, width, height)
      out = [Text.pad(@p.bold(" #{title}"), width), Text.pad(@p.dim(" " + "─" * [width - 2, 0].max), width)]
      lines.last(height - 2).each { |l| out << Text.pad(" " + l, width) }
      out
    end

    # Centre a block of lines over the frame.
    def overlay(lines, block, width)
      block_w = block.map { |l| Text.width(l) }.max || 0
      left = [(width - block_w) / 2, 0].max
      top = [(lines.size - block.size) / 2, 0].max
      out = lines.dup
      block.each_with_index do |bl, i|
        y = top + i
        next if y >= out.size
        base = Text.strip_ansi(out[y])
        prefix = Text.pad(Text.take(base, left), left)
        suffix_start = left + block_w
        suffix = Text.strip_ansi(base)
        suffix = drop_columns(suffix, suffix_start)
        out[y] = Text.pad(prefix + Text.pad(bl, block_w) + suffix, width)
      end
      out
    end

    def drop_columns(s, n)
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
  end

  # Diffs successive frames and writes only changed rows.
  class Painter
    def initialize(out, cursor: TTY::Cursor)
      @out = out
      @cursor = cursor
      @prev = []
    end

    def paint(lines, force: false)
      buf = +""
      buf << @cursor.clear_screen if force
      lines.each_with_index do |line, i|
        next if !force && @prev[i] == line
        buf << @cursor.move_to(0, i) << line << @cursor.clear_line_after
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
