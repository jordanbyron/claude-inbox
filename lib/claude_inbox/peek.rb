# frozen_string_literal: true

module ClaudeInbox
  # The peek pane: whether it is open, which row it is on, how far back it
  # is scrolled, and what to paint for that. The lines themselves come from
  # Logs, which it asks on every selection change so that opening the pane
  # lands on a warm cache. Main-thread state only.
  class Peek
    TERMINAL_NOTE = "This is a claude you opened in a terminal yourself. The daemon can't attach to it, read its output, or stop it from outside. Switch to that window."
    REMOTE_NOTE = "This is a Remote Control session driven from claude.ai/code. The daemon can't attach to it or read its output from here. Open it in the web or mobile app instead."

    # What Renderer paints: the body lines, the title bar, the dim line under it.
    View = Struct.new(:lines, :title, :subtitle)

    def initialize(logs)
      @logs = logs
      @open = false
      @offset = 0
      @selected = nil
      @session = nil
    end

    def open? = @open

    def toggle
      @open = !@open
      @logs.want(@session.id) if @open && @session&.actionable?
    end

    def close = @open = false

    # Called on every selection change. `session` is the selected session
    # when the key names one; a fold has none.
    def select(key, session)
      @selected = key
      @session = session
      @offset = 0
      @logs.want(session.id) if session&.actionable?
    end

    # Positive scrolls back into history, negative towards the tail.
    def scroll(delta)
      @offset = [@offset + delta, 0].max
    end

    # `row` is the selected row as the frame shows it, or nil when nothing is
    # selected. Answers nil when there is no pane to paint.
    def view(row, height)
      return nil unless @open && @selected.is_a?(String)
      View.new(scrolled(body(row), height - 2), row&.label || @selected, subtitle(row))
    end

    private

    def body(row)
      return ["(nothing selected)"] unless row
      return interactive_note(row.session) if row.session.interactive?
      @logs.cached(row.session.id) || ["(loading…)"]
    end

    def interactive_note(s)
      [s.remote? ? REMOTE_NOTE : TERMINAL_NOTE, "", "pid #{s.pid} · #{s.cwd}", "session #{s.session_id}"]
    end

    def subtitle(row)
      return nil unless row
      s = row.session
      parts = [s.effective_state, s.status, s.waiting_for, s.id, s.started_at&.strftime("started %b %-d %H:%M")].compact
      parts += s.prs.map { |pr| "#{pr.short} #{pr.state&.downcase || "?"}" }
      parts.join(" · ")
    end

    # Lines are shown tail-first; the offset scrolls back into history and is
    # clamped to however much history there is.
    def scrolled(lines, view_h)
      return lines if @offset.zero?
      max_off = [lines.size - view_h, 0].max
      @offset = [@offset, max_off].min
      lines[0, lines.size - @offset]
    end
  end
end
