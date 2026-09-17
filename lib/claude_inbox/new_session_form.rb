# frozen_string_literal: true

require_relative "agents_client"
require_relative "settings"
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
    end

    def focused = @fields[@focus]

    # => :cancel | :start | :start_and_attach | :changed
    def press(name, raw)
      @error = nil
      @candidates = nil
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
      :changed
    end

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

    # Full-screen body: a tall prompt editor, then one row per setting with
    # every choice visible. Exactly `height` lines.
    def screen(width, height)
      inner_w = width - 4
      fixed = 3 + 2 + 1 + (@fields.size - 1) + 1
      prompt_h = [height - fixed, 3].max
      out = [""]
      out << "  " + @p.bold("New session")
      out << ""
      out << "  " + field_label(@fields[0]) + @p.dim("  ⏎ newline")
      out += prompt_box(@fields[0], inner_w, prompt_h)
      out << ""
      @fields[1..].each { |f| out << "  " + field_label(f) + field_value(f, inner_w - 14) }
      out.first(height) + [""] * [height - out.size, 0].max
    end

    def footer
      return @p.red(@error) if @error
      return @p.dim("matches: ") + @candidates.join(@p.dim("  ")) if @candidates
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
