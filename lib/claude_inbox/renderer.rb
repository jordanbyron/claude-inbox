# frozen_string_literal: true

require "pastel"
require "tty-cursor"
require_relative "text"
require_relative "palette"
require_relative "theme"
require_relative "store"

module ClaudeInbox
  # sections -> Array<String> (one entry per terminal row, each exactly
  # `width` columns wide) plus a parallel Array of selectable items.
  # Pure: no terminal, no IO, no clock beyond the `now` it is handed.
  class Renderer
    Item = Struct.new(:kind, :row, :section) do
      def selection = (kind == :fold_toggle) ? Store::Selection.fold(section) : Store::Selection.row(row.key)

      def key = selection.key
    end

    Frame = Struct.new(:lines, :items, :top, :list_width)

    SECTION_TITLES = {
      pinned: "PINNED",
      needs_you: "NEEDS YOU",
      active: "ACTIVE",
      snoozed: "SNOOZED",
      settled: "SETTLED"
    }.freeze

    SPINNER = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze

    # The first poll usually lands inside a second. Past LOADING_QUIET the
    # wait is long enough to feel like a hang, so it gets some company; past
    # LOADING_HINT_AFTER it is long enough to be one.
    LOADING_QUIET = 1.5
    LOADING_HINT_AFTER = 10
    QUIPS = [
      "asking the daemon nicely…",
      "counting agents…",
      "reticulating splines…",
      "herding sessions…",
      "checking behind the couch…",
      "reading the process tree…",
      "polishing the spinner…",
      "still here…"
    ].freeze

    KEYS = [
      ["j/k", "move"], ["⏎", "attach"], ["n", "new"], ["t", "pin"], ["s", "snooze"], ["u", "wake"],
      ["a", "alias"], ["o", "PR"], ["x", "settle"], ["p", "peek"], ["⇥", "section"],
      ["za", "fold"], ["/", "filter"], ["q", "quit"]
    ].freeze

    def initialize(color: true, min_left: 44, home: Dir.home)
      @p = Pastel.new(enabled: color)
      @theme = Theme.new(enabled: color)
      @palette = Palette.new(enabled: color)
      @min_left = min_left
      @home = home
    end

    def caret = ->(cell) { @p.inverse(cell) }

    # opts: selected (id | :snoozed | :settled | nil), expanded ({snoozed:, settled:} => bool), top (scroll),
    #       peek (Array<String> | nil), peek_title, modal (Array<String> | nil),
    #       status (String | nil, a notice or error at the header's right end),
    #       usage (String | nil, the rate-limit label after it), now (Time), filter (TextBuffer | nil), filter_editing, command (TextBuffer | nil),
    #       tick (Integer, drives the spinner),
    #       loading (Float seconds waited for the first poll, nil once it has landed),
    #       screen ({lines:, footer:} takes over everything below the header)
    def frame(sections, width:, height:, now:, **opts)
      return full_screen(sections, width, height, now, opts) if opts[:screen]
      selected = opts[:selected]
      list_w = width_for_list(width, opts[:peek])
      view_h = height - 2 # header + footer
      body, items =
        if opts[:loading]
          [loading_state(list_w, view_h, opts[:loading], opts[:tick].to_i), []]
        else
          body_lines(sections, list_w, selected, opts, now)
        end

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

      lines = [header(sections, width, opts, now)] + visible.map { |l| Text.pad(l, width) } + [footer(width, opts)]
      lines = overlay(lines, opts[:modal], width) if opts[:modal]
      Frame.new(lines, [nil] + visible_items + [nil], top, list_w)
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
      lines = [header(sections, width, opts, now)] + body.map { |l| Text.pad(l, width) } + [Text.pad(" " + opts[:screen][:footer], width)]
      Frame.new(lines, [nil] * (view_h + 2), opts[:top] || 0, width)
    end

    # ----- chrome -------------------------------------------------------------

    def header(sections, width, opts, now)
      brand = " " + @theme.cyan_bold("▌ claude-inbox")
      right = [opts[:status], opts[:usage]].compact.map { |s| @p.dim(s) }.join(@p.dim("  ·  "))
      right += " " unless right.empty?
      room = width - Text.width(brand) - Text.width(right) - 3
      chips = opts[:loading] ? "" : header_chips(sections, compact: false)
      chips = header_chips(sections, compact: true) if Text.width(chips) > room
      chips = "" if Text.width(chips) > room
      Text.pad(brand + "   " + chips, width - Text.width(right)) + right
    end

    def header_chips(sections, compact:)
      pn = sections.pinned.size
      n = sections.needs_you.size
      w = sections.active.count { |r| r.session.effective_state == "working" && !r.session.waiting_on_work? }
      q = sections.active.count { |r| r.session.waiting_on_work? }
      i = sections.all.count { |r| r.session.terminal? }
      m = sections.all.count { |r| r.session.remote? }
      z = sections.snoozed.size
      d = sections.settled.size
      chips = []
      chips << @theme.cyan_bold(compact ? "★ #{pn}" : "★ #{pn} pinned") if pn > 0
      chips << @theme.red_bold(compact ? "● #{n}" : "● #{n} need#{"s" if n == 1} you") if n > 0
      chips << @theme.yellow(compact ? "✻ #{w}" : "✻ #{w} working") if w > 0
      chips << @theme.yellow(compact ? "◌ #{q}" : "◌ #{q} idle") if q > 0
      chips << @p.dim(compact ? "○ #{i}" : "○ #{i} terminal#{"s" if i > 1}") if i > 0
      chips << @theme.blue(compact ? "⇅ #{m}" : "⇅ #{m} remote") if m > 0
      chips << @theme.purple(compact ? "z #{z}" : "z #{z} snoozed") if z > 0
      chips << @p.dim(compact ? "◦ #{d}" : "◦ #{d} settled") if d > 0
      chips << @p.dim("nothing running") if sections.all.empty?
      chips.join(compact ? "  " : @p.dim("  ·  "))
    end

    def footer(width, opts)
      text =
        if opts[:command] then " " + @theme.cyan_bold(":") + line(opts[:command], width - 2)
        elsif opts[:filter_editing] then " " + @theme.cyan_bold("/") + line(opts[:filter], width - 2)
        elsif opts[:filter] then " " + @theme.cyan_bold("/") + opts[:filter].to_s + @p.dim("  esc clears")
        else " " + KEYS.map { |k, d| @theme.cyan_bold(k) + " " + @p.dim(d) }.join("  ")
        end
      Text.pad(text, width)
    end

    def line(buffer, width) = buffer.row(width, cursor: caret)

    def section_title(name, count, width)
      title = " #{SECTION_TITLES[name]} "
      count_s = " #{count} "
      fill = [width - 3 - Text.width(title) - Text.width(count_s), 0].max
      color = section_color(name)
      Text.pad(" " + color.call("▎") + color.call(@p.bold(title)) + @p.dim("─" * fill) + @p.dim(count_s), width)
    end

    def section_color(name)
      case name
      when :pinned then ->(s) { @theme.cyan(s) }
      when :needs_you then ->(s) { @theme.red(s) }
      when :active then ->(s) { @theme.yellow(s) }
      when :snoozed then ->(s) { @theme.purple(s) }
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
      expanded = opts[:expanded] || {}
      sections.each_section do |name, rows|
        next if rows.empty?
        lines << "" << section_title(name, rows.size, width)
        items << nil << nil
        if Store.folded?(name, expanded)
          lines << fold_toggle_line(name, rows.size, selected, width)
          items << Item.new(:fold_toggle, nil, name)
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

    # Nothing to list yet and no way to know whether that means nothing is
    # running, so neither the empty state nor the chips. A short wait gets
    # a blank body; a long one gets a spinner, a dot pacing its tray and a
    # rotating excuse, with the elapsed time so a hang looks like one.
    def loading_state(width, height, waited, tick)
      return [] if waited < LOADING_QUIET
      block = [
        centered(@theme.cyan_bold(SPINNER[tick % SPINNER.size]), width),
        "",
        centered(tray(tick), width),
        "",
        centered(QUIPS[(tick / 6) % QUIPS.size], width),
        centered(@p.dim("waiting on claude agents · #{waited.floor}s"), width)
      ]
      if waited >= LOADING_HINT_AFTER
        block << "" << centered(@p.dim("slow? ") + @theme.cyan("claude daemon status") + @p.dim(" says whether the daemon is up"), width)
      end
      [""] * [(height - block.size) / 2, 0].max + block
    end

    TRAY_SLOTS = 9

    # A dot bouncing between the ends of a tray, one slot per tick.
    def tray(tick)
      span = TRAY_SLOTS - 1
      i = tick % (span * 2)
      pos = (i <= span) ? i : span * 2 - i
      cells = Array.new(TRAY_SLOTS) { |j| (j == pos) ? @theme.cyan_bold("●") : @p.dim("·") }
      @p.dim("▌") + " " + cells.join(" ") + " " + @p.dim("▐")
    end

    def centered(s, width)
      left = [(width - Text.width(s)) / 2, 0].max
      Text.pad(" " * left + s, width)
    end

    def empty_state(width)
      [
        "", "",
        Text.pad("   " + @p.bold("Nothing running."), width),
        Text.pad("   " + @p.dim("Start one from any terminal with ") + @theme.cyan("claude --bg \"task\""), width),
        Text.pad("   " + @p.dim("or press ") + @theme.cyan("R") + @p.dim(" to poll again."), width)
      ]
    end

    def fold_toggle_line(name, count, selected, width)
      sel = selected == name
      marker = sel ? @theme.cyan_bold("▶") : " "
      text = @p.dim("… #{count} #{SECTION_TITLES[name].downcase}") + (sel ? @p.dim("   ⏎ or zo to expand") : "")
      Text.pad(" #{marker} " + text, width)
    end

    def row_lines(row, section, selected, width, now, tick)
      s = row.session
      sel = row.selectable? && selected == row.key
      marker = sel ? @theme.cyan_bold("▶") : " "
      glyph = glyph_for(s, section, tick)
      meta = meta_for(row, section, now)

      # " " marker " " glyph " " label "  " meta "  " project " "
      chrome = 1 + 1 + 1 + 1 + 1 + 2 + Text.width(meta) + 2 + 1
      # Project is only cut once the label has given up all its space too,
      # so the row can never exceed `width` and fall into Text.pad's blind
      # tail-chop (which used to land mid-project-name with no ellipsis).
      project_text = Text.truncate(s.project, [width - chrome, 0].max)
      project = (section == :settled) ? @p.dim(project_text) : @theme.cyan(project_text)

      label_w = [width - chrome - Text.width(project_text), 0].max
      label = Text.truncate(row.label, label_w)
      label = style_label(label, row, section, sel)
      first = " #{marker} #{glyph} " + Text.pad(label, label_w) + "  " + meta + "  " + project + " "

      return [Text.pad(first, width)] unless %i[pinned needs_you active].include?(section)

      # The session's own line when it has one; the path is what is left to
      # say about a terminal, which has no job file.
      detail = @p.dim("       ↳ " + Text.truncate(s.summary || short_path(s.cwd), [width - 10, 0].max))
      [Text.pad(first, width), Text.pad(detail, width)]
    end

    # The label is the one part of a row you own: `/color` tints it, and
    # nothing else on the line. Glyph, badge and PR keep the state's colors,
    # so no color you pick can make a blocked session stop looking blocked.
    # Settled stays dim — the section is meant to be quiet.
    def style_label(label, row, section, sel)
      return @p.dim(label) if section == :settled
      styled =
        if row.alias_name then sel ? @p.bold.italic(label) : @p.italic(label)
        elsif sel then @p.bold(label)
        else label
        end
      @palette.paint(styled, row.session.color)
    end

    def glyph_for(s, section, tick)
      return @theme.purple("z") if section == :snoozed
      return @p.dim("◦") if section == :settled
      case s.effective_state
      when "blocked" then @theme.red_bold("●")
      when "failed" then @theme.red_bold("✗")
      when "working" then s.waiting_on_work? ? @theme.yellow("◌") : @theme.yellow(SPINNER[tick % SPINNER.size])
      when "done" then @theme.green("✓")
      when "stopped" then @p.dim("■")
      else @p.dim("?")
      end
    end

    def meta_for(row, section, now)
      s = row.session
      base =
        case section
        when :snoozed
          row.parked? ? @theme.purple("parked") : @theme.purple("wakes in #{Text.age(row.wake_at.to_i - now.to_i)}")
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

    # "#885 open" in GitHub's colors: green open, dim draft, purple merged,
    # red closed. Only the first PR is shown; the peek subtitle lists them all.
    def pr_badge(s, section)
      pr = s.pr
      return nil unless pr
      return @p.dim("#{pr.short} #{pr.state&.downcase}".strip) if section == :settled
      case pr.state
      when "OPEN" then @theme.green("#{pr.short} open")
      when "DRAFT" then @p.dim("#{pr.short} draft")
      when "MERGED" then @theme.purple("#{pr.short} merged")
      when "CLOSED" then @theme.red("#{pr.short} closed")
      else @p.dim(pr.short)
      end
    end

    def state_badge(s)
      case s.effective_state
      when "blocked"
        detail = s.waiting_for ? ": #{s.waiting_for}" : ""
        @theme.red_bold("needs you#{detail}")
      when "failed" then @theme.red_bold("failed")
      when "working" then working_badge(s)
      when "done" then @theme.green("done") + ((s.alive? && !s.interactive?) ? @p.dim(" · #{s.status}") : "")
      when "stopped" then @p.dim("stopped")
      else @p.dim(s.state.to_s)
      end
    end

    # "working" while the agent is thinking, "idle" once it has stopped and
    # only the work it kicked off is still open — with that work named either
    # way, since "working · 2 agents" is the answer to "working on what?".
    def working_badge(s)
      return @theme.yellow("waiting#{": #{s.waiting_for}" if s.waiting_for}") if s.status == "waiting"
      label = s.job_state&.in_flight_label
      @theme.yellow(s.waiting_on_work? ? "idle" : "working") + (label ? @p.dim(" · #{label}") : "")
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
        suffix = Text.drop(base, left + block_w)
        out[y] = Text.pad(@p.dim(prefix) + Text.pad(bl, block_w) + @p.dim(suffix), width)
      end
      out
    end
  end

  # Diffs successive frames and writes only changed rows. No erase-to-end-of-
  # line after a row: in the terminal's last column the cursor stays put
  # (pending wrap), so EL would eat the glyph just drawn.
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
