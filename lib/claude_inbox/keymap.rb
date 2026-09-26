# frozen_string_literal: true

module ClaudeInbox
  # Pure key -> action resolver with vim-style chords. The App feeds it one
  # keypress at a time (the tty-reader key name plus the raw string) and gets
  # back an action symbol, or nil while a chord is pending.
  #
  #   km = Keymap.new
  #   km.press(:down, "j")   # => :down
  #   km.press("g", "g")     # => nil   (pending)
  #   km.press("g", "g")     # => :top
  class Keymap
    CHORD_TIMEOUT = 1.0

    BINDINGS = {
      # motion
      "j" => :down, :down => :down,
      "k" => :up, :up => :up,
      "G" => :bottom,
      :ctrl_d => :half_page_down, :ctrl_u => :half_page_up,
      :ctrl_f => :page_down, :ctrl_b => :page_up,
      :ctrl_e => :peek_down, :ctrl_y => :peek_up,
      "J" => :peek_down, "K" => :peek_up,
      # actions
      :return => :activate, :enter => :activate, "l" => :activate,
      "h" => :collapse,
      "s" => :snooze, "u" => :wake, "a" => :alias, "x" => :settle, "X" => :stop,
      :ctrl_x => :delete,
      "o" => :open_pr, "P" => :link_pr, "t" => :toggle_pin, "w" => :open_remote,
      "R" => :refresh, "p" => :toggle_peek, "n" => :new_session, "N" => :remote_pairing,
      :tab => :next_section, :back_tab => :prev_section,
      "/" => :filter, :escape => :escape,
      "q" => :quit, :ctrl_c => :quit
    }.freeze

    CHORDS = {
      "g" => {"g" => :top},
      "z" => {"o" => :fold_open, "c" => :fold_close, "a" => :fold_toggle}
    }.freeze

    attr_reader :pending

    def initialize(clock: -> { Time.now })
      @clock = clock
      @pending = nil
      @pending_at = nil
    end

    def press(name, raw)
      expire_pending
      if @pending
        table = CHORDS[@pending]
        @pending = nil
        return table[raw] # nil on an unknown second key, chord dropped
      end
      if CHORDS.key?(raw)
        @pending = raw
        @pending_at = @clock.call
        return nil
      end
      BINDINGS[name] || BINDINGS[raw]
    end

    private

    def expire_pending
      return unless @pending && @clock.call - @pending_at > CHORD_TIMEOUT
      @pending = nil
    end
  end
end
