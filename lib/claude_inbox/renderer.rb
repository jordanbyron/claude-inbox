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
    Item = Struct.new(:kind, :row, :section) do
      def id = row&.id

      def key = (kind == :settled_toggle) ? :settled : row&.key
    end

    Frame = Struct.new(:lines, :items, :top)

    SECTION_TITLES = {
      pinned: "PINNED",
      needs_you: "NEEDS YOU",
      working: "WORKING",
      snoozed: "SNOOZED",
      settled: "SETTLED"
    }.freeze

    SPINNER = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze

    KEYS = [
      ["j/k", "move"], ["⏎", "attach"], ["n", "new"], ["t", "pin"], ["s", "snooze"], ["u", "wake"],
      ["a", "alias"], ["o", "PR"], ["x", "stop"], ["p", "peek"], ["⇥", "section"],
      ["za", "fold"], ["/", "filter"], [":q", "quit"]
    ].freeze

    def initialize(color: true, min_left: 44, home: Dir.home)
      @p = Pastel.new(enabled: color)
      @min_left = min_left
      @home = home
    end

    # opts: selected (id | :settled | nil), settled_expanded, top (scroll),
    #       peek (Array<String> | nil), peek_title, modal (Array<String> | nil),
    #       status (String), now (Time), filter (String | nil), command,
    #       tick (Integer, drives the spinner),
    #       screen ({lines:, footer:} takes over everything below the header)
    def frame(sections, width:, height:, now:, **opts)
      return full_screen(sections, width, height, now, opts) if opts[:screen]
      selected = opts[:selected]
      list_w = width_for_list(width, opts[:peek])
      body, items = body_lines(sections, list_w, selected, opts, now)

      view_h = height - 2 # header + footer
      top = clamp_top(opts[:top] || 0, body.size, view_h, items, selected)
      visible = body[top, view_h] || []
      visible_items = items[top, view_h] || []
      visible += [""] * (view_h - visible.size)
      visible_items += [nil] * (view_h - visible_items.size)

      if opts[:peek]
        peek_w = width - list_w - 1
        peek_lines = peek_pane(opts[:peek], opts[:peek_title], opts[:peek_subtitle], peek_w, view_h)
        visible = visible.each_with_index.map do |l, i|
          Text.pad(l, list_w) + @p.dim("│") + Text.pad(peek_lines[i] || "", peek_w)
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
      top = idx - 2 if idx && idx - 2 < top # keep the section title in view
      top = idx - view_h + 1 if idx && idx >= top + view_h
      top.clamp(0, [size - view_h, 0].max)
    end

    def full_screen(sections, width, height, now, opts)
      view_h = height - 2
      body = opts[:screen][:lines].first(view_h)
      body += [""] * (view_h - body.size)
      lines = [header(sections, width, opts[:status], now)] + body.map { |l| Text.pad(l, width) } + [Text.pad(" " + opts[:screen][:footer], width)]
      Frame.new(lines, [nil] * (view_h + 2), opts[:top] || 0)
    end

    # ----- chrome -------------------------------------------------------------

    def header(sections, width, status, now)
      brand = " " + @p.cyan.bold("▌ claude-inbox")
      right = status ? @p.dim(status) + " " : ""
      room = width - Text.width(brand) - Text.width(right) - 3
      chips = header_chips(sections, compact: false)
      chips = header_chips(sections, compact: true) if Text.width(chips) > room
      chips = "" if Text.width(chips) > room
      Text.pad(brand + "   " + chips, width - Text.width(right)) + right
    end

    def header_chips(sections, compact:)
      pn = sections.pinned.size
      n = sections.needs_you.size
      w = sections.working.count { |r| r.session.effective_state == "working" }
      i = sections.all.count { |r| r.session.terminal? }
      m = sections.all.count { |r| r.session.remote? }
      z = sections.snoozed.size
      d = sections.settled.size
      chips = []
      chips << @p.cyan.bold(compact ? "★ #{pn}" : "★ #{pn} pinned") if pn > 0
      chips << @p.red.bold(compact ? "● #{n}" : "● #{n} need#{"s" if n == 1} you") if n > 0
      chips << @p.yellow(compact ? "✻ #{w}" : "✻ #{w} working") if w > 0
      chips << @p.dim(compact ? "○ #{i}" : "○ #{i} terminal#{"s" if i > 1}") if i > 0
      chips << @p.blue(compact ? "⇅ #{m}" : "⇅ #{m} remote") if m > 0
      chips << @p.magenta(compact ? "z #{z}" : "z #{z} snoozed") if z > 0
      chips << @p.dim(compact ? "∙ #{d}" : "∙ #{d} settled") if d > 0
      chips << @p.dim("nothing running") if sections.all.empty?
      chips.join(compact ? "  " : @p.dim("  ·  "))
    end

    def footer(width, opts)
      text =
        if opts[:command] then " " + @p.cyan.bold(":") + opts[:command] + @p.dim("▏")
        elsif opts[:filter] then " " + @p.cyan.bold("/") + opts[:filter] + (opts[:filter_editing] ? @p.dim("▏") : @p.dim("  esc clears"))
        else " " + KEYS.map { |k, d| @p.cyan.bold(k) + " " + @p.dim(d) }.join("  ")
        end
      Text.pad(text, width)
    end

    def section_title(name, count, width)
      title = " #{SECTION_TITLES[name]} "
      count_s = " #{count} "
      fill = [width - 3 - Text.width(title) - Text.width(count_s), 0].max
      color = section_color(name)
      Text.pad(" " + color.call("▎") + color.call(@p.bold(title)) + @p.dim("─" * fill) + @p.dim(count_s), width)
    end

    def section_color(name)
      case name
      when :pinned then ->(s) { @p.cyan(s) }
      when :needs_you then ->(s) { @p.red(s) }
      when :working then ->(s) { @p.yellow(s) }
      when :snoozed then ->(s) { @p.magenta(s) }
      else ->(s) { @p.dim(s) }
      end
    end

    # ----- body ---------------------------------------------------------------

    def body_lines(sections, width, selected, opts, now)
      lines = []
      items = []
      if sections.all.empty?
        return [empty_state(width), []]
      end
      sections.each_section do |name, rows|
        next if rows.empty?
        lines << "" << section_title(name, rows.size, width)
        items << nil << nil
        if name == :settled && !opts[:settled_expanded]
          lines << settled_toggle(rows.size, selected, width)
          items << Item.new(:settled_toggle, nil, :settled)
          next
        end
        rows.each do |row|
          row_lines(row, name, selected, width, now, opts[:tick].to_i).each_with_index do |l, i|
            lines << l
            items << ((i.zero? && row.selectable?) ? Item.new(:row, row, name) : nil)
          end
        end
      end
      [lines, items]
    end

    def empty_state(width)
      [
        "", "",
        Text.pad("   " + @p.bold("Nothing running."), width),
        Text.pad("   " + @p.dim("Start one from any terminal with ") + @p.cyan("claude --bg \"task\""), width),
        Text.pad("   " + @p.dim("or press ") + @p.cyan("R") + @p.dim(" to poll again."), width)
      ]
    end

    def settled_toggle(count, selected, width)
      sel = selected == :settled
      marker = sel ? @p.cyan.bold("▶") : " "
      text = @p.dim("… #{count} settled") + (sel ? @p.dim("   ⏎ or zo to expand") : "")
      Text.pad(" #{marker} " + text, width)
    end

    def row_lines(row, section, selected, width, now, tick)
      s = row.session
      sel = row.selectable? && selected == row.key
      marker = sel ? @p.cyan.bold("▶") : " "
      glyph = glyph_for(s, section, tick)
      project = @p.cyan(s.project)
      project = @p.dim(s.project) if section == :settled
      meta = meta_for(row, section, now)

      # " " marker " " glyph " " label "  " meta "  " project
      fixed = 1 + 1 + 1 + 1 + 1 + 2 + Text.width(meta) + 2 + Text.width(project)
      label_w = [width - fixed, 8].max
      label = Text.truncate(row.label, label_w)
      label = style_label(label, row, section, sel)
      first = " #{marker} #{glyph} " + Text.pad(label, label_w) + "  " + meta + "  " + project

      return [Text.pad(first, width)] unless %i[pinned needs_you working].include?(section)

      detail = @p.dim("       ↳ #{short_path(s.cwd)}")
      [Text.pad(first, width), Text.pad(detail, width)]
    end

    def style_label(label, row, section, sel)
      row.session
      if section == :settled then @p.dim(label)
      elsif row.alias_name then sel ? @p.bold.italic(label) : @p.italic(label)
      elsif sel then @p.bold(label)
      else label
      end
    end

    def glyph_for(s, section, tick)
      return @p.magenta("z") if section == :snoozed
      return @p.dim("∙") if section == :settled
      case s.effective_state
      when "blocked" then @p.red.bold("●")
      when "failed" then @p.red.bold("✗")
      when "working" then @p.yellow(SPINNER[tick % SPINNER.size])
      when "done" then @p.green("✓")
      when "stopped" then @p.dim("■")
      else @p.dim("?")
      end
    end

    def meta_for(row, section, now)
      s = row.session
      base =
        case section
        when :snoozed
          row.parked? ? @p.magenta("parked") : @p.magenta("wakes in #{Text.age(row.wake_at.to_i - now.to_i)}")
        when :settled
          @p.dim("#{s.state} · #{Text.age(now.to_i - row.state_since.to_i)}")
        else
          if s.interactive?
            where = s.remote? ? "remote" : "your terminal"
            age = row.state_since ? Text.age(now.to_i - row.state_since.to_i) : Text.age(now - s.started_at)
            state_badge(s) + @p.dim(" · #{where} · #{age}")
          else
            age = row.state_since ? @p.dim(" · " + Text.age(now.to_i - row.state_since.to_i)) : ""
            state_badge(s) + age
          end
        end
      pr = pr_badge(s, section)
      pr ? base + @p.dim(" · ") + pr : base
    end

    # "#885 open" in GitHub's colours: green open, dim draft, purple merged,
    # red closed. Only the first PR is shown; the peek subtitle lists them all.
    def pr_badge(s, section)
      pr = s.pr
      return nil unless pr
      return @p.dim("#{pr.short} #{pr.state&.downcase}".strip) if section == :settled
      case pr.state
      when "OPEN" then @p.green("#{pr.short} open")
      when "DRAFT" then @p.dim("#{pr.short} draft")
      when "MERGED" then @p.magenta("#{pr.short} merged")
      when "CLOSED" then @p.red("#{pr.short} closed")
      else @p.dim(pr.short)
      end
    end

    def state_badge(s)
      case s.effective_state
      when "blocked"
        detail = s.waiting_for ? ": #{s.waiting_for}" : ""
        @p.red.bold("needs you#{detail}")
      when "failed" then @p.red.bold("failed")
      when "working"
        (s.status == "waiting") ? @p.yellow("waiting#{": #{s.waiting_for}" if s.waiting_for}") : @p.yellow("working")
      when "done" then @p.green("done") + ((s.alive? && !s.interactive?) ? @p.dim(" · #{s.status}") : "")
      when "stopped" then @p.dim("stopped")
      else @p.dim(s.state.to_s)
      end
    end

    def short_path(path)
      return "" unless path
      path.start_with?(@home) ? path.sub(@home, "~") : path
    end

    # ----- peek ---------------------------------------------------------------

    def peek_pane(lines, title, subtitle, width, height)
      bar = Text.pad(" " + (title || ""), width)
      out = [@p.inverse(bar)]
      out << Text.pad(" " + @p.dim(subtitle.to_s), width) if subtitle
      body_h = height - out.size
      wrapped = lines.flat_map { |l| Text.wrap(l, width - 1) }
      wrapped.last(body_h).each { |l| out << Text.pad(" " + l, width) }
      out
    end

    # ----- modal --------------------------------------------------------------

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
        suffix = drop_columns(base, left + block_w)
        out[y] = Text.pad(@p.dim(prefix) + Text.pad(bl, block_w) + @p.dim(suffix), width)
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
