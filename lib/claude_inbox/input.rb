# frozen_string_literal: true

require "tty-reader"
require_relative "mouse"
require_relative "paste"

module ClaudeInbox
  # The tty's keypress stream decoded into pastes, mouse reports and named
  # keys. Hides what tty-reader does with ESC, echo and a paste, so App sees
  # events and not the raw bytes.
  class Input
    # macOS sends Option-s as "\es", so an Esc glued to one lowercase letter
    # is taken as Option held with it.
    ALT = /\A\e([a-z])\z/

    # A nonblocking read can end partway through a mouse report.
    UNFINISHED_REPORT = /\e\[<[\d;]*\z/

    def self.alt?(name) = name.to_s.start_with?("alt_")

    # An Option chord as the quick Esc-then-letter it may also have been.
    def self.unglued(raw) = [[:escape, "\e"], [raw[1], raw[1]]]

    def initialize(input, out)
      @input = input
      @reader = TTY::Reader.new(input: input, output: out, interrupt: :noop)
      @paste = Paste.new
      @held = +""
    end

    def pasting? = @paste.pasting?

    # The next raw read, or nil when nothing has arrived.
    def read
      pasting? ? read_pasted : @reader.read_keypress(echo: false, raw: false, nonblock: true)
    end

    # `[:paste, text]`, `[:mouse, event]` and `[:key, name, raw]`, in the
    # order they arrived; `name` is the reader's symbol for a key it knows,
    # else the raw string. The head of a report cut off at the end of a read
    # waits for the rest instead of being typed.
    def events(raw)
      @paste.feed(raw).flat_map do |kind, text|
        next [[:paste, text]] if kind == :paste
        text = @held + text
        @held = text[UNFINISHED_REPORT] || +""
        Mouse.split(text.delete_suffix(@held)).flat_map do |piece|
          next [[:mouse, piece]] if piece.is_a?(Mouse::Event)
          split_keys(piece).map { |k| [:key, key_name(k), k] }
        end
      end
    end

    # A paste typed out: `[name, raw]` per character.
    def typed(text) = text.each_char.map { |c| [key_name(c), c] }

    private

    # As much of an open paste as has arrived, read straight off the tty:
    # the reader switches echo off and back on around every character, and
    # on a long paste that is most of the wait.
    def read_pasted
      return nil unless @input.wait_readable(0.1)
      out = +""
      while out.size < 65_536 && @input.wait_readable(0) && (c = @input.getc)
        out << c
      end
      out
    end

    def key_name(key) = @reader.console.keys[key] || key[ALT, 1]&.then { |c| :"alt_#{c}" } || key

    # tty-reader glues ESC to whatever arrives within 100ms, so a fast
    # "esc gg" comes in as one unknown key "\egg". Vim hands make that
    # constantly. Unknown ESC-prefixed strings become ESC + the rest.
    def split_keys(key)
      return [key] if key.size <= 1 || @reader.console.keys.key?(key)
      return [key] unless key.start_with?("\e")
      return [key] if key.match?(ALT)
      ["\e"] + key[1..].chars
    end
  end
end
