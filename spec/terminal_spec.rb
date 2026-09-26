# frozen_string_literal: true

require "stringio"

RSpec.describe ClaudeInbox::Terminal do
  let(:out) { StringIO.new }
  let(:input) { StringIO.new }
  let(:terminal) { described_class.new(out, input) }

  context "once it enters the alt screen" do
    before { terminal.enter }

    it "takes the wheel" do
      expect(out.string).to include(described_class::ALT_ON)
      expect(out.string).to include(described_class::WHEEL_KEYS_ON)
    end

    it("takes over the mouse") { expect(out.string).to include(described_class::MOUSE_ON) }

    it("asks for bracketed paste") { expect(out.string).to include(described_class::PASTE_ON) }

    it "hands the screen to a child and takes it back afterwards" do
      in_child = nil
      terminal.release { in_child = out.string.rindex(described_class::ALT_OFF) > out.string.rindex(described_class::ALT_ON) }
      expect(in_child).to be(true)
      expect(out.string.rindex(described_class::ALT_ON)).to be > out.string.rindex(described_class::ALT_OFF)
    end

    # Each mode belongs to the alt screen, so it has to go first.
    context "and restores" do
      before do
        out.string = +""
        terminal.restore
      end

      it "hands the wheel back before leaving the alt screen" do
        expect(out.string.index(described_class::WHEEL_KEYS_OFF)).to be < out.string.index(described_class::ALT_OFF)
      end

      it "hands the mouse back before leaving the alt screen" do
        expect(out.string.index(described_class::MOUSE_OFF)).to be < out.string.index(described_class::ALT_OFF)
      end

      it "hands bracketed paste back before leaving the alt screen" do
        expect(out.string.index(described_class::PASTE_OFF)).to be < out.string.index(described_class::ALT_OFF)
      end

      it "restores once, however many times it is asked" do
        terminal.restore
        expect(out.string.scan(described_class::ALT_OFF).size).to eq(1)
      end
    end
  end

  context "on a tty with a mode of its own" do
    let(:input) { ModedInput.new }

    it "hands the tty back in the mode it found it, not a stock cooked one" do
      terminal.enter
      terminal.restore
      expect(input.modes).to eq([:shell, :raw, :shell])
    end
  end

  it "never lets the frame get smaller than the renderer can lay out" do
    cols, rows = terminal.size
    expect(cols).to be >= 40
    expect(rows).to be >= 8
  end
end
