# frozen_string_literal: true

require "io/console"
require "tty-cursor"
require "tty-screen"
require_relative "renderer"

module ClaudeInbox
  # The screen the inbox draws on: the alt screen and the mouse and wheel
  # modes that come and go with it, raw mode on the input, the cached size,
  # and the Painter that diffs frames onto it. `release` hands the whole
  # thing to a child that wants the tty and takes it back afterwards.
  class Terminal
    ALT_ON = "\e[?1049h"
    ALT_OFF = "\e[?1049l"
    # Alternate scroll mode: while the alt screen is up the terminal turns
    # wheel ticks into cursor keys, so a scroll moves the selection instead of
    # dragging the scrollback we are covering into view. Terminals that don't
    # know the mode ignore it and keep scrolling their own history.
    WHEEL_KEYS_ON = "\e[?1007h"
    WHEEL_KEYS_OFF = "\e[?1007l"
    # Real mouse reporting: button events plus the SGR encoding, so clicks
    # and wheel ticks arrive as escape sequences we parse ourselves (Mouse)
    # instead of the terminal only ever translating the wheel to arrow
    # keys. Terminals that don't understand either mode just ignore it and
    # fall back to WHEEL_KEYS_ON's translation, or their own scrollback.
    MOUSE_ON = "\e[?1000h\e[?1006h"
    MOUSE_OFF = "\e[?1006l\e[?1000l"
    # Bracketed paste: what is pasted arrives fenced off from what is typed
    # (Paste), and a pasted image, which has no text, arrives as an empty
    # fence rather than not at all.
    PASTE_ON = "\e[?2004h"
    PASTE_OFF = "\e[?2004l"

    def initialize(out, input)
      @out = out
      @input = input
      @painter = Painter.new(out)
      @restored = true
      @size = nil
    end

    def enter
      @out.print ALT_ON, WHEEL_KEYS_ON, MOUSE_ON, PASTE_ON, TTY::Cursor.hide, TTY::Cursor.clear_screen
      @out.flush
      @input.raw! if @input.respond_to?(:raw!) && @input.tty?
      @restored = false
      resized
    end

    # Safe to call twice, and from at_exit: the second call is a no-op.
    def restore
      return if @restored
      @restored = true
      @input.cooked! if @input.respond_to?(:cooked!) && @input.tty?
      @out.print TTY::Cursor.show, PASTE_OFF, MOUSE_OFF, WHEEL_KEYS_OFF, ALT_OFF
      @out.flush
    rescue
      nil
    end

    # Gives the tty to the block, cleared and in cooked mode, and comes back
    # to a fresh alt screen whatever the block did.
    def release
      restore
      @out.print TTY::Cursor.clear_screen
      @out.flush
      yield
    ensure
      enter
    end

    # [cols, rows]. Cached: querying the terminal can fall back to spawning
    # `tput`, which is far too slow to do on every frame. Refreshed by
    # `resized`, which WINCH and re-entry both call.
    def size
      @size ||= measure
    end

    def resized
      @size = nil
      @painter.invalidate
    end

    def paint(lines) = @painter.paint(lines)

    # Repaint every row on the next frame.
    def invalidate = @painter.invalidate

    private

    def measure
      rows, cols = begin
        (@out.respond_to?(:winsize) && @out.tty?) ? @out.winsize : TTY::Screen.size
      rescue
        TTY::Screen.size
      end
      [[cols, 40].max, [rows, 8].max]
    end
  end
end
