# frozen_string_literal: true

require_relative "agents_client"
require_relative "text"

module ClaudeInbox
  # State and key handling for the "new session" modal. Pure: returns what
  # happened so the App can act on it. Rendering returns plain lines; the
  # App wraps them in a box.
  class NewSessionForm
    Field = Struct.new(:key, :label, :kind, :value, :choices)

    def initialize(cwd:, pastel:)
      @p = pastel
      @fields = [
        Field.new(:prompt, "Prompt", :text, +""),
        Field.new(:name, "Name", :text, +""),
        Field.new(:cwd, "Directory", :text, +cwd.to_s),
        Field.new(:model, "Model", :choice, "default", AgentsClient::MODELS),
        Field.new(:effort, "Effort", :choice, "default", AgentsClient::EFFORTS),
        Field.new(:permission_mode, "Permissions", :choice, "default", AgentsClient::PERMISSION_MODES),
        Field.new(:worktree, "Worktree", :choice, "no", %w[no yes])
      ]
      @focus = 0
      @error = nil
    end

    def focused = @fields[@focus]

    # => :cancel | :submit | :changed | nil
    def press(name, raw)
      @error = nil
      case name
      when :escape then return :cancel
      when :tab, :down then move(1)
      when :back_tab, :up then move(-1)
      when :return, :enter then return submit
      when :ctrl_u then focused.value = +"" if focused.kind == :text
      when :backspace, :ctrl_h then focused.value.slice!(-1) if focused.kind == :text
      when :left then cycle(-1)
      when :right then cycle(1)
      else
        if focused.kind == :text
          focused.value << raw if raw.is_a?(String) && raw.match?(/\A[[:print:]]\z/)
        elsif raw == "h" then cycle(-1)
        elsif raw == "l" || raw == " " then cycle(1)
        end
      end
      :changed
    end

    def values
      @fields.to_h { |f| [f.key, f.value] }.tap do |v|
        v[:worktree] = v[:worktree] == "yes"
        v[:name] = nil if v[:name].strip.empty?
        v[:cwd] = File.expand_path(v[:cwd].strip.empty? ? "." : v[:cwd].strip)
      end
    end

    def lines(width)
      label_w = 12
      val_w = width - label_w - 6
      out = @fields.each_with_index.map do |f, i|
        focused = i == @focus
        marker = focused ? @p.cyan.bold("▶") : " "
        label = Text.pad(f.label, label_w)
        label = focused ? @p.bold(label) : @p.dim(label)
        value =
          if f.kind == :text
            v = Text.truncate(f.value, val_w - 1)
            v = @p.dim("(none)") if v.empty? && f.key == :name && !focused
            focused ? v + @p.cyan("▏") : v
          else
            (focused ? @p.cyan("‹ ") : "  ") + @p.bold(f.value) + (focused ? @p.cyan(" ›") : "")
          end
        " #{marker} #{label} #{value}"
      end
      out << ""
      out << " " + (@error ? @p.red(@error) : @p.dim("⇥ next field · ← → h l change · ⏎ start · esc cancel"))
      out
    end

    private

    def move(d) = @focus = (@focus + d) % @fields.size

    def cycle(d)
      f = focused
      return unless f.kind == :choice
      f.value = f.choices[(f.choices.index(f.value) + d) % f.choices.size]
    end

    def submit
      v = values
      if v[:prompt].strip.empty?
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
