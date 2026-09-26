# frozen_string_literal: true

require_relative "../lib/claude_inbox/mouse"

RSpec.describe ClaudeInbox::Mouse do
  def events(raw) = ClaudeInbox::Mouse.events(raw)

  def event(...) = ClaudeInbox::Mouse::Event.new(...)

  it "parses a left click press" do
    expect(events("\e[<0;5;3M")).to eq([event(:click, 3, 5)])
  end

  it "ignores a release" do
    expect(events("\e[<0;5;3m")).to eq([])
  end

  it "ignores the middle and right buttons" do
    expect(events("\e[<1;5;3M")).to eq([])
    expect(events("\e[<2;5;3M")).to eq([])
  end

  it "ignores a drag" do
    expect(events("\e[<32;5;3M")).to eq([])
  end

  it "counts a shift-click as a click" do
    expect(events("\e[<4;5;3M")).to eq([event(:click, 3, 5)])
  end

  it "parses wheel ticks by direction" do
    expect(events("\e[<64;1;1M")).to eq([event(:scroll_up, 1, 1)])
    expect(events("\e[<65;1;1M")).to eq([event(:scroll_down, 1, 1)])
  end

  it "reads a modifier-held wheel tick the same way" do
    expect(events("\e[<80;1;1M")).to eq([event(:scroll_up, 1, 1)])
  end

  it "scans several reports glued onto one read" do
    expect(events("\e[<0;5;3M\e[<0;5;3m\e[<65;2;2M")).to eq([
      event(:click, 3, 5), event(:scroll_down, 2, 2)
    ])
  end

  it "returns nothing for an ordinary keypress" do
    expect(events("j")).to eq([])
  end
end
