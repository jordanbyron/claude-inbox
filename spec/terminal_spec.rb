# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/claude_inbox/terminal"
require "stringio"

# A tty with a mode of its own, as io/console exposes one.
class ModedInput < StringIO
  attr_reader :modes

  def initialize
    super
    @modes = [:shell]
  end

  def tty? = true

  def raw! = @modes << :raw

  def console_mode = @modes.last

  def console_mode=(mode)
    @modes << mode
  end
end

describe ClaudeInbox::Terminal do
  let(:out) { StringIO.new }
  let(:terminal) { ClaudeInbox::Terminal.new(out, StringIO.new) }

  # StringIO#string hands back the live buffer, so copy before clearing it.
  def taken = out.string.dup.tap {
    out.truncate(0)
    out.rewind
  }

  it "takes the wheel for the duration of the alt screen and hands it back" do
    terminal.enter
    entered = taken
    _(entered).must_include ClaudeInbox::Terminal::ALT_ON
    _(entered).must_include ClaudeInbox::Terminal::WHEEL_KEYS_ON

    terminal.restore
    left = taken
    _(left).must_include ClaudeInbox::Terminal::WHEEL_KEYS_OFF
    # The mode belongs to the alt screen, so it has to go first.
    _(left.index(ClaudeInbox::Terminal::WHEEL_KEYS_OFF)).must_be :<, left.index(ClaudeInbox::Terminal::ALT_OFF)
  end

  it "takes over the mouse for the duration of the alt screen and hands it back" do
    terminal.enter
    entered = taken
    _(entered).must_include ClaudeInbox::Terminal::MOUSE_ON

    terminal.restore
    left = taken
    _(left).must_include ClaudeInbox::Terminal::MOUSE_OFF
    _(left.index(ClaudeInbox::Terminal::MOUSE_OFF)).must_be :<, left.index(ClaudeInbox::Terminal::ALT_OFF)
  end

  it "asks for bracketed paste for the duration of the alt screen and hands it back" do
    terminal.enter
    _(taken).must_include ClaudeInbox::Terminal::PASTE_ON

    terminal.restore
    left = taken
    _(left).must_include ClaudeInbox::Terminal::PASTE_OFF
    _(left.index(ClaudeInbox::Terminal::PASTE_OFF)).must_be :<, left.index(ClaudeInbox::Terminal::ALT_OFF)
  end

  it "restores once, however many times it is asked" do
    terminal.enter
    taken
    terminal.restore
    terminal.restore
    _(taken.scan(ClaudeInbox::Terminal::ALT_OFF).size).must_equal 1
  end

  it "hands the screen to a child and takes it back afterwards" do
    terminal.enter
    taken
    order = []
    terminal.release { order << taken.include?(ClaudeInbox::Terminal::ALT_OFF) }
    _(order).must_equal [true]
    _(taken).must_include ClaudeInbox::Terminal::ALT_ON
  end

  it "hands the tty back in the mode it found it, not a stock cooked one" do
    input = ModedInput.new
    terminal = ClaudeInbox::Terminal.new(out, input)
    terminal.enter
    terminal.restore
    _(input.modes).must_equal [:shell, :raw, :shell]
  end

  it "never lets the frame get smaller than the renderer can lay out" do
    cols, rows = terminal.size
    _(cols).must_be :>=, 40
    _(rows).must_be :>=, 8
  end
end
