# frozen_string_literal: true

require_relative "agents_client"
require_relative "images"
require_relative "settings"
require_relative "slash_commands"
require_relative "text"
require_relative "text_buffer"
require_relative "theme"

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

    def initialize(cwd:, pastel:, theme: Theme.new(enabled: pastel.enabled), home: Dir.home, clipboard: Images.method(:from_clipboard))
      @p = pastel
      @theme = theme
      @home = home
      @clipboard = clipboard
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
      @confirm_discard = false
      @busy = false
    end

    def focused = @fields[@focus]

    # => :cancel | :start | :start_and_attach | :changed
    def press(name, raw)
      # `:start`/`:start_and_attach` leave the form up until the spawn is
      # known to have worked, so a failure (untrusted directory, `claude`
      # missing, ...) can hand the composed prompt back instead of losing
      # it; there is no way to cancel a spawn already under way, so every
      # key is swallowed until the App reports back.
      return :changed if @busy
      return confirm_discard_press(name, raw) if @confirm_discard
      @error = nil
      @candidates = nil
      return :changed if menu && menu_press(name)
      before = command_query
      case name
      when :escape then return escape_pressed
      when :ctrl_s then return submit(attach: false)
      when :ctrl_o then return submit(attach: true)
      when :ctrl_v then paste_clipboard
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

    # A bracketed paste. Empty is how a terminal pastes an image: there is
    # no text to send, so the clipboard is read directly, the way Claude
    # Code does on Cmd-V. A dropped file arrives as its path, and an image
    # becomes a chip in the prompt rather than text.
    def paste(text)
      @error = nil
      text = text.gsub(/\r\n?/, "\n")
      if text.empty?
        paste_clipboard
      elsif focused.key == :prompt && (path = Images.dropped(text))
        focused.value.attach(path)
      else
        insert(text)
      end
      :changed
    end

    def command_query
      return nil unless focused.key == :prompt
      focused.value.head[/(?:\A|\s)\/(\S*)\z/, 1]
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
        v[:prompt] = field(:prompt).value.expand { |chip| AgentsClient.mention(chip.path) }.strip
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
      title = @busy ? @p.dim("Starting session…") : @p.bold("New session")
      out << "  " + (@confirm_discard ? @theme.red("Discard this session? (y/n)") : title)
      out << ""
      out << "  " + field_label(field(:prompt)) + @p.dim("  ⏎ newline")
      out += prompt_box(field(:prompt), inner_w, prompt_h)
      out += menu_rows
      out << ""
      @fields[1..].each { |f| out << "  " + field_label(f) + field_value(f, inner_w - 14) }
      out.first(height) + [""] * [height - out.size, 0].max
    end

    def footer
      return @p.dim("starting session…") if @busy
      return hints([["y", "discard"], ["esc", "keep editing"]]) if @confirm_discard
      return @theme.red(@error) if @error
      return @p.dim("matches: ") + @candidates.join(@p.dim("  ")) if @candidates
      return hints([["↑ ↓", "choose"], ["⇥ ⏎", "pick"], ["esc", "close"]]) if menu
      keys =
        case focused.kind
        when :multiline then [["⏎", "newline"], ["^V", "image"]]
        when :choice then [["← → h l", "change"], ["⏎", "next"]]
        else [["⏎", "next"]]
        end
      keys += [["^S", "start"], ["^O", "start & open"],
        ["⇥", (focused.key == :cwd) ? "complete / next" : "next"], ["esc", "cancel"]]
      hints(keys)
    end

    # The App's `claude --bg` call failed after `:start`/`:start_and_attach`
    # already handed the form off — an untrusted directory, a stale binary,
    # a permissions error. The composed prompt is still here, so the form
    # reopens on it with the reason shown instead of the App just logging
    # the failure and losing the draft.
    def submission_failed(message)
      @busy = false
      @error = message
    end

    private

    # Esc with a prompt typed asks first, so a stray keypress can't lose it.
    def escape_pressed
      return :cancel if field(:prompt).value.empty?
      @confirm_discard = true
      :changed
    end

    def confirm_discard_press(name, raw)
      return :cancel if raw == "y"
      @confirm_discard = false if name == :escape || raw == "n" || raw == "q"
      :changed
    end

    def paste_clipboard
      clip = @clipboard.call
      if clip.image
        return @error = "images go in the prompt" unless focused.key == :prompt
        focused.value.attach(clip.image)
      elsif clip.text
        insert(clip.text)
      else
        @error = "nothing on the clipboard"
      end
    end

    def insert(text)
      return unless editable?
      focused.value.insert((focused.kind == :multiline) ? text : text.tr("\n", " "))
    end

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
      focused.value.replace_before(command_query.grapheme_clusters.size + 1, "#{cmd} ")
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
        "    " + (on ? @theme.pill(" #{name} ", :cyan) : @theme.cyan(" #{name} ")) + " " + (on ? desc : @p.dim(desc))
      end
      rows[-1] = Text.pad(rows[-1], w - more.size) + @p.dim(more)
      rows
    end

    def hints(pairs) = pairs.map { |k, d| @theme.cyan_bold(k) + " " + @p.dim(d) }.join("  ")

    def field_label(f)
      on = f.equal?(focused)
      (on ? @theme.cyan_bold("▶ ") : "  ") + (on ? @p.bold(Text.pad(f.label, 12)) : @p.dim(Text.pad(f.label, 12)))
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
          if c == f.value then (on ? @theme.pill(" #{text} ", :cyan) : @theme.cyan_bold(" #{text} "))
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
      edge = on ? ->(s) { @theme.cyan(s) } : ->(s) { @p.dim(s) }
      rows, hidden = f.value.view(w - 4, h, cursor: (caret if on), chip: ->(s) { @theme.cyan_bold(s) })
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

    def field(key) = @fields.find { |f| f.key == key }

    def focus_on(key) = @focus = @fields.index { |f| f.key == key }

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
        focus_on(:prompt)
        return :changed
      end
      unless File.directory?(v[:cwd])
        @error = "no such directory: #{v[:cwd]}"
        focus_on(:cwd)
        return :changed
      end
      @busy = true
      attach ? :start_and_attach : :start
    end
  end
end
