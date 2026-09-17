# frozen_string_literal: true

require_relative "agents_client"
require_relative "settings"
require_relative "text"

module ClaudeInbox
  # State and key handling for the "new session" modal. Pure: returns what
  # happened so the App can act on it. Rendering returns plain lines; the
  # App wraps them in a box.
  class NewSessionForm
    Field = Struct.new(:key, :label, :kind, :value, :choices)

    # "default" stays the internal value so spawn_args leaves the flag off;
    # the screen shows what that resolves to instead.
    DEFAULT = "default"

    def initialize(cwd:, pastel:, home: Dir.home)
      @p = pastel
      @home = home
      @fields = [
        Field.new(:prompt, "Prompt", :multiline, +""),
        Field.new(:name, "Name", :text, +""),
        Field.new(:cwd, "Directory", :text, +cwd.to_s),
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

    # => :cancel | :submit | :changed | nil
    def press(name, raw)
      @error = nil
      @candidates = nil
      case name
      when :escape then return :cancel
      when :ctrl_s then return submit
      when :tab then complete_dir || move(1)
      when :down then move(1)
      when :back_tab, :up then move(-1)
      when :return, :enter
        return submit unless focused.kind == :multiline
        focused.value << "\n"
      when :ctrl_u then focused.value = +"" if editable?
      when :backspace, :ctrl_h then focused.value.slice!(-1) if editable?
      when :left then cycle(-1)
      when :right then cycle(1)
      else
        if editable?
          focused.value << raw if raw.is_a?(String) && raw.match?(/\A[[:print:]]\z/)
        elsif raw == "h" then cycle(-1)
        elsif raw == "l" || raw == " " then cycle(1)
        end
      end
      :changed
    end

    def values
      @fields.to_h { |f| [f.key, f.value] }.tap do |v|
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
      keys = focused.kind == :multiline ? [["⏎", "newline"], ["^S", "start"]] : [["← → h l", "change"], ["⏎ ^S", "start"]]
      keys += [["⇥", focused.key == :cwd ? "complete / next" : "next"], ["esc", "cancel"]]
      keys.map { |k, d| @p.cyan.bold(k) + " " + @p.dim(d) }.join("  ")
    end

    private

    def field_label(f)
      on = f.equal?(focused)
      (on ? @p.cyan.bold("▶ ") : "  ") + (on ? @p.bold(Text.pad(f.label, 12)) : @p.dim(Text.pad(f.label, 12)))
    end

    def field_value(f, w)
      on = f.equal?(focused)
      if f.kind == :text
        v = Text.truncate(f.value, w - 1)
        v = @p.dim(f.key == :name ? "(none — claude picks one)" : "") if v.empty? && !on
        on ? v + @p.cyan("▏") : v
      else
        f.choices.map { |c|
          text = c == DEFAULT ? default_text(f) : c
          if c == f.value then (on ? @p.black.on_cyan(" #{text} ") : @p.cyan.bold(" #{text} "))
          else @p.dim(" #{text} ")
          end
        }.join(" ")
      end
    end

    def default_text(f)
      resolved = {model: defaults.model, effort: defaults.effort, permission_mode: defaults.permission_mode}[f.key]
      resolved ? "#{resolved} (settings)" : "auto (cli default)"
    end

    def prompt_box(f, w, h)
      on = f.equal?(focused)
      edge = on ? ->(s) { @p.cyan(s) } : ->(s) { @p.dim(s) }
      rows = f.value.split("\n", -1).flat_map { |l| l.empty? ? [""] : Text.wrap(l, w - 4) }
      rows = [""] if rows.empty?
      hidden = [rows.size - h, 0].max
      rows = rows.last(h)
      rows[-1] = rows[-1] + @p.cyan("▏") if on
      rows[0] = @p.dim("… #{hidden} more ") + rows[0] if hidden > 0
      rows[0] = @p.dim("What should this session do?") if f.value.empty? && !on
      rows += [""] * (h - rows.size)
      top = "  " + edge.("┌" + "─" * (w - 2) + "┐")
      bottom = "  " + edge.("└" + "─" * (w - 2) + "┘")
      [top] + rows.map { |r| "  " + edge.("│") + " " + Text.pad(r, w - 4) + " " + edge.("│") } + [bottom]
    end




    # Tab in the Directory field: extend the path as far as the matching
    # directories agree, listing them while it is still ambiguous. Returns
    # nil when the path is already a directory or matches nothing, so the
    # caller can treat Tab as "next field" instead.
    def complete_dir
      return nil unless focused.key == :cwd
      typed = focused.value
      base = File.expand_path(typed.empty? ? "." : typed)
      listing = typed.empty? || typed.end_with?("/")
      return nil if !listing && File.directory?(base)
      matches = Dir.glob(listing ? "#{base}/*" : "#{base}*").select { |d| File.directory?(d) }.sort
      return nil if matches.empty?
      if matches.size == 1
        focused.value = +"#{matches.first}/"
      else
        @candidates = matches.map { |d| File.basename(d) }
        focused.value = +common_prefix(matches)
      end
      :changed
    end

    def common_prefix(paths)
      first, *rest = paths
      first.each_char.with_index.reduce("") do |acc, (c, i)|
        rest.all? { |o| o[i] == c } ? acc + c : (break acc)
      end
    end

    def editable? = %i[text multiline].include?(focused.kind)

    def move(d) = @focus = (@focus + d) % @fields.size

    def cycle(d)
      f = focused
      return unless f.kind == :choice
      f.value = f.choices[(f.choices.index(f.value) + d) % f.choices.size]
    end

    def submit
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
      :submit
    end
  end
end
