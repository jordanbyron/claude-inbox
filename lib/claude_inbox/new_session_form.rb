# frozen_string_literal: true

require_relative "agents_client"
require_relative "settings"
require_relative "slash_commands"
require_relative "text"
require_relative "text_buffer"

module ClaudeInbox
  # State and key handling for the "new session" modal. Pure: returns what
  # happened so the App can act on it. Rendering returns plain lines; the
  # App wraps them in a box.
  class NewSessionForm
    # `value` is a TextBuffer on :text and :multiline fields and the picked
    # string on :choice ones — `kind` says which.
    Field = Struct.new(:key, :label, :kind, :value, :choices)

    # "default" stays the internal value so spawn_args leaves the flag off;
    # the screen shows what that resolves to instead.
    DEFAULT = "default"

    MENU_ROWS = 6

    def initialize(cwd:, pastel:, home: Dir.home)
      @p = pastel
      @home = home
      @fields = [
        Field.new(:prompt, "Prompt", :multiline, TextBuffer.new),
        Field.new(:name, "Name", :text, TextBuffer.new),
        Field.new(:cwd, "Directory", :text, TextBuffer.new(cwd.to_s)),
        Field.new(:model, "Model", :choice, DEFAULT, AgentsClient::MODELS),
        Field.new(:effort, "Effort", :choice, DEFAULT, AgentsClient::EFFORTS),
        Field.new(:permission_mode, "Permissions", :choice, DEFAULT, AgentsClient::PERMISSION_MODES),
        Field.new(:worktree, "Worktree", :choice, "no", %w[no yes])
      ]
      @focus = 0
      @error = nil
      @defaults_for = nil
      @commands_for = nil
      @pick = 0
      @dismissed = nil
    end

    def focused = @fields[@focus]

    # => :cancel | :start | :start_and_attach | :changed
    def press(name, raw)
      @error = nil
      @candidates = nil
      return :changed if menu && menu_press(name)
      before = command_query
      case name
      when :escape then return :cancel
      when :ctrl_s then return submit(attach: false)
      when :ctrl_o then return submit(attach: true)
      when :tab then complete_dir || move(1)
      when :down then move(1)
      when :back_tab, :up then move(-1)
      when :return, :enter
        (focused.kind == :multiline) ? focused.value.insert("\n") : move(1)
      else
        editable? ? focused.value.press(name, raw) : choose(name, raw)
      end
      edited = before && command_query && command_query != before
      @pick = 0 if edited
      @dismissed = nil if edited
      :changed
    end

    # Anchored to the prompt's first word so a `/` in a path further along
    # never opens the menu.
    def command_query
      return nil unless focused.key == :prompt
      focused.value.head[/\A\/(\S*)\z/, 1]
    end

    def menu
      q = command_query
      return nil if q.nil? || @dismissed == q
      found = SlashCommands.match(commands, q)
      found.empty? ? nil : found
    end

    def picked = menu&.fetch(@pick.clamp(0, menu.size - 1))

    def values
      @fields.to_h { |f| [f.key, f.value.to_s] }.tap do |v|
        v[:prompt] = v[:prompt].strip
        v[:worktree] = v[:worktree] == "yes"
        v[:name] = nil if v[:name].strip.empty?
        v[:cwd] = File.expand_path(v[:cwd].strip.empty? ? "." : v[:cwd].strip)
      end
    end

    # Settings resolve against the directory the session will run in, so
    # they follow the Directory field.
    def defaults
      cwd = values[:cwd]
      return @defaults if @defaults_for == cwd
      @defaults_for = cwd
      @defaults = Settings.defaults(cwd, home: @home)
    end

    # Project commands live under the Directory field's path, so they
    # follow it as the defaults do.
    def commands
      cwd = values[:cwd]
      return @commands if @commands_for == cwd
      @commands_for = cwd
      @commands = SlashCommands.list(cwd: cwd, home: @home)
    end

    # Full-screen body: a tall prompt editor, then one row per setting with
    # every choice visible. Exactly `height` lines.
    def screen(width, height)
      inner_w = width - 4
      fixed = 3 + 2 + 1 + (@fields.size - 1) + 1
      menu_rows = menu_lines(inner_w, [height - fixed - 3, MENU_ROWS].min)
      prompt_h = [height - fixed - menu_rows.size, 3].max
      out = [""]
      out << "  " + @p.bold("New session")
      out << ""
      out << "  " + field_label(@fields[0]) + @p.dim("  ⏎ newline")
      out += prompt_box(@fields[0], inner_w, prompt_h)
      out += menu_rows
      out << ""
      @fields[1..].each { |f| out << "  " + field_label(f) + field_value(f, inner_w - 14) }
      out.first(height) + [""] * [height - out.size, 0].max
    end

    def footer
      return @p.red(@error) if @error
      return @p.dim("matches: ") + @candidates.join(@p.dim("  ")) if @candidates
      if menu
        return [["↑ ↓", "choose"], ["⇥ ⏎", "pick"], ["esc", "close"]]
            .map { |k, d| @p.cyan.bold(k) + " " + @p.dim(d) }.join("  ")
      end
      keys =
        case focused.kind
        when :multiline then [["⏎", "newline"]]
        when :choice then [["← → h l", "change"], ["⏎", "next"]]
        else [["⏎", "next"]]
        end
      keys += [["^S", "start"], ["^O", "start & open"],
        ["⇥", (focused.key == :cwd) ? "complete / next" : "next"], ["esc", "cancel"]]
      keys.map { |k, d| @p.cyan.bold(k) + " " + @p.dim(d) }.join("  ")
    end

    private

    def menu_press(name)
      case name
      when :up, :ctrl_p then @pick = (@pick - 1) % menu.size
      when :down, :ctrl_n then @pick = (@pick + 1) % menu.size
      when :tab, :return, :enter then accept(picked)
      when :escape then @dismissed = command_query
      else return false
      end
      true
    end

    def accept(cmd)
      focused.value.replace_head("#{cmd} ")
      @pick = 0
    end

    # Scrolled so the pick never falls off the bottom; the count of what is
    # cut rides on the last row rather than costing one of its own.
    def menu_lines(w, h)
      items = menu
      return [] if items.nil? || h <= 0
      pick = @pick.clamp(0, items.size - 1)
      first = [pick - h + 1, 0].max
      shown = items[first, h]
      left = items.size - first - shown.size
      more = (left > 0) ? "  +#{left} more" : ""
      name_w = [shown.map { |c| Text.width(c.to_s) }.max, 36].min
      rows = shown.each_with_index.map do |c, i|
        on = first + i == pick
        name = Text.pad(c.to_s, name_w)
        tag = (i == shown.size - 1) ? more.size : 0
        desc = Text.truncate(c.description, w - name_w - 8 - tag)
        "    " + (on ? @p.black.on_cyan(" #{name} ") : @p.cyan(" #{name} ")) + " " + (on ? desc : @p.dim(desc))
      end
      rows[-1] = Text.pad(rows[-1], w - more.size) + @p.dim(more)
      rows
    end

    def field_label(f)
      on = f.equal?(focused)
      (on ? @p.cyan.bold("▶ ") : "  ") + (on ? @p.bold(Text.pad(f.label, 12)) : @p.dim(Text.pad(f.label, 12)))
    end

    # The cell the cursor sits on, drawn as a block by inverting it: a bar
    # between cells would shift everything after it a column to the right.
    def caret = ->(cell) { @p.inverse(cell) }

    def field_value(f, w)
      on = f.equal?(focused)
      if f.kind == :text
        return f.value.row(w, cursor: caret) if on
        if f.value.empty?
          @p.dim((f.key == :name) ? "(none — claude picks one)" : "")
        else
          f.value.row(w)
        end
      else
        f.choices.map { |c|
          text = (c == DEFAULT) ? default_text(f) : c
          if c == f.value then (on ? @p.black.on_cyan(" #{text} ") : @p.cyan.bold(" #{text} "))
          else @p.dim(" #{text} ")
          end
        }.join(" ")
      end
    end

    def default_text(f)
      resolved = defaults[f.key]
      resolved ? "#{resolved} (settings)" : "auto (cli default)"
    end

    def prompt_box(f, w, h)
      on = f.equal?(focused)
      edge = on ? ->(s) { @p.cyan(s) } : ->(s) { @p.dim(s) }
      rows, hidden = f.value.view(w - 4, h, cursor: (caret if on))
      rows = [@p.dim("What should this session do?")] if f.value.empty? && !on
      rows += [""] * (h - rows.size)
      [top_edge(edge, w, hidden)] +
        rows.map { |r| "  " + edge.call("│") + " " + Text.pad(r, w - 4) + " " + edge.call("│") } +
        ["  " + edge.call("└" + "─" * (w - 2) + "┘")]
    end

    # How much of a long prompt is scrolled out of sight goes in the top
    # border, where it can't collide with the text or the cursor.
    def top_edge(edge, w, hidden)
      label = (hidden > 0) ? @p.dim(" ↑ #{hidden} more ") : ""
      "  " + edge.call("┌" + "─" * (w - 2 - Text.width(label))) + label + edge.call("┐")
    end

    # Tab in the Directory field: extend the path as far as the matching
    # directories agree, listing them while it is still ambiguous. Returns
    # nil when the path is already a directory or matches nothing, so the
    # caller can treat Tab as "next field" instead.
    def complete_dir
      return nil unless focused.key == :cwd
      typed = focused.value.to_s
      base = File.expand_path(typed.empty? ? "." : typed)
      listing = typed.empty? || typed.end_with?("/")
      return nil if !listing && File.directory?(base)
      matches = Dir.glob(listing ? "#{base}/*" : "#{base}*").select { |d| File.directory?(d) }.sort
      return nil if matches.empty?
      if matches.size == 1
        focused.value.replace("#{matches.first}/")
      else
        @candidates = matches.map { |d| File.basename(d) }
        focused.value.replace(common_prefix(matches))
      end
      :changed
    end

    def common_prefix(paths)
      first, *rest = paths
      first.each_char.with_index.reduce("") do |acc, (c, i)|
        (rest.all? { |o| o[i] == c }) ? acc + c : (break acc)
      end
    end

    def editable? = %i[text multiline].include?(focused.kind)

    def move(d) = @focus = (@focus + d) % @fields.size

    # Keys a :choice field answers to; an editable field spends these on its
    # own text instead.
    def choose(name, raw)
      case name
      when :left then cycle(-1)
      when :right then cycle(1)
      else
        case raw
        when "h" then cycle(-1)
        when "l", " " then cycle(1)
        end
      end
    end

    def cycle(d)
      f = focused
      return unless f.kind == :choice
      f.value = f.choices[(f.choices.index(f.value) + d) % f.choices.size]
    end

    def submit(attach:)
      v = values
      if v[:prompt].empty?
        @error = "a prompt is required"
        @focus = 0
        return :changed
      end
      unless File.directory?(v[:cwd])
        @error = "no such directory: #{v[:cwd]}"
        @focus = 2
        return :changed
      end
      attach ? :start_and_attach : :start
    end
  end
end
