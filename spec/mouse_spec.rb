# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/claude_inbox/mouse"

describe ClaudeInbox::Mouse do
  def events(raw) = ClaudeInbox::Mouse.events(raw)

  def event(...) = ClaudeInbox::Mouse::Event.new(...)

  it "parses a left click press" do
    _(events("\e[<0;5;3M")).must_equal [event(:click, 3, 5)]
  end

  it "ignores a release" do
    _(events("\e[<0;5;3m")).must_equal []
  end

  it "ignores the middle and right buttons" do
    _(events("\e[<1;5;3M")).must_equal []
    _(events("\e[<2;5;3M")).must_equal []
  end

  it "ignores a drag" do
    _(events("\e[<32;5;3M")).must_equal []
  end

  it "counts a shift-click as a click" do
    _(events("\e[<4;5;3M")).must_equal [event(:click, 3, 5)]
  end

  it "parses wheel ticks by direction" do
    _(events("\e[<64;1;1M")).must_equal [event(:scroll_up, 1, 1)]
    _(events("\e[<65;1;1M")).must_equal [event(:scroll_down, 1, 1)]
  end

  it "reads a modifier-held wheel tick the same way" do
    _(events("\e[<80;1;1M")).must_equal [event(:scroll_up, 1, 1)]
  end

  it "scans several reports glued onto one read" do
    _(events("\e[<0;5;3M\e[<0;5;3m\e[<65;2;2M")).must_equal [
      event(:click, 3, 5), event(:scroll_down, 2, 2)
    ]
  end

  it "returns nothing for an ordinary keypress" do
    _(events("j")).must_equal []
  end
end
