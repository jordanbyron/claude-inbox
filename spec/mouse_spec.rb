# frozen_string_literal: true

RSpec.describe ClaudeInbox::Mouse do
  it "parses a left click press" do
    expect(described_class.split("\e[<0;5;3M")).to eq([described_class::Event.new(:click, 3, 5)])
  end

  it "ignores a release" do
    expect(described_class.split("\e[<0;5;3m")).to eq([])
  end

  it "ignores the middle and right buttons" do
    expect(described_class.split("\e[<1;5;3M")).to eq([])
    expect(described_class.split("\e[<2;5;3M")).to eq([])
  end

  it "ignores a drag" do
    expect(described_class.split("\e[<32;5;3M")).to eq([])
  end

  it "reads the pointer moving with no button held, where it is" do
    expect(described_class.split("\e[<35;12;4M")).to eq([described_class::Event.new(:move, 4, 12)])
  end

  it "counts a shift-click as a click" do
    expect(described_class.split("\e[<4;5;3M")).to eq([described_class::Event.new(:click, 3, 5)])
  end

  it "parses wheel ticks by direction" do
    expect(described_class.split("\e[<64;1;1M")).to eq([described_class::Event.new(:scroll_up, 1, 1)])
    expect(described_class.split("\e[<65;1;1M")).to eq([described_class::Event.new(:scroll_down, 1, 1)])
  end

  it "reads a modifier-held wheel tick the same way" do
    expect(described_class.split("\e[<80;1;1M")).to eq([described_class::Event.new(:scroll_up, 1, 1)])
  end

  it "scans several reports glued onto one read" do
    expect(described_class.split("\e[<0;5;3M\e[<0;5;3m\e[<65;2;2M")).to eq([
      described_class::Event.new(:click, 3, 5), described_class::Event.new(:scroll_down, 2, 2)
    ])
  end

  it "passes an ordinary keypress through as keys" do
    expect(described_class.split("j")).to eq(["j"])
  end

  it "cuts the keys around a report apart, in order, whether it is acted on or not" do
    expect(described_class.split("j\e[<0;5;3Mk")).to eq(["j", described_class::Event.new(:click, 3, 5), "k"])
    expect(described_class.split("\e\e[<0;5;3mg")).to eq(["\e", "g"])
  end
end
