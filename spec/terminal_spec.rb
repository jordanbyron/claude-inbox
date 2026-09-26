# frozen_string_literal: true

require "stringio"

RSpec.describe ClaudeInbox::Terminal do
  let(:out) { StringIO.new }
  let(:terminal) { described_class.new(out, StringIO.new) }

  it "takes the wheel for the duration of the alt screen and hands it back" do
    terminal.enter
    entered = drain(out)
    expect(entered).to include(described_class::ALT_ON)
    expect(entered).to include(described_class::WHEEL_KEYS_ON)

    terminal.restore
    left = drain(out)
    expect(left).to include(described_class::WHEEL_KEYS_OFF)
    # The mode belongs to the alt screen, so it has to go first.
    expect(left.index(described_class::WHEEL_KEYS_OFF)).to be < left.index(described_class::ALT_OFF)
  end

  it "takes over the mouse for the duration of the alt screen and hands it back" do
    terminal.enter
    entered = drain(out)
    expect(entered).to include(described_class::MOUSE_ON)

    terminal.restore
    left = drain(out)
    expect(left).to include(described_class::MOUSE_OFF)
    expect(left.index(described_class::MOUSE_OFF)).to be < left.index(described_class::ALT_OFF)
  end

  it "asks for bracketed paste for the duration of the alt screen and hands it back" do
    terminal.enter
    expect(drain(out)).to include(described_class::PASTE_ON)

    terminal.restore
    left = drain(out)
    expect(left).to include(described_class::PASTE_OFF)
    expect(left.index(described_class::PASTE_OFF)).to be < left.index(described_class::ALT_OFF)
  end

  it "restores once, however many times it is asked" do
    terminal.enter
    drain(out)
    terminal.restore
    terminal.restore
    expect(drain(out).scan(described_class::ALT_OFF).size).to eq(1)
  end

  it "hands the screen to a child and takes it back afterwards" do
    terminal.enter
    drain(out)
    order = []
    terminal.release { order << drain(out).include?(described_class::ALT_OFF) }
    expect(order).to eq([true])
    expect(drain(out)).to include(described_class::ALT_ON)
  end

  it "hands the tty back in the mode it found it, not a stock cooked one" do
    input = ModedInput.new
    terminal = described_class.new(out, input)
    terminal.enter
    terminal.restore
    expect(input.modes).to eq([:shell, :raw, :shell])
  end

  it "never lets the frame get smaller than the renderer can lay out" do
    cols, rows = terminal.size
    expect(cols).to be >= 40
    expect(rows).to be >= 8
  end
end
