# frozen_string_literal: true

RSpec.describe ClaudeInbox::TextBuffer do
  let(:mark) { ->(cell) { "[#{cell}]" } }

  it "types where the cursor is" do
    b = described_class.new("ad")
    b.press(:left, "\e[D")
    "bc".each_char { |c| b.press(c, c) }
    expect(b.to_s).to eq("abcd")
    expect(b.cursor).to eq(3)
  end

  it "stops at both ends instead of wrapping around" do
    b = described_class.new("ab")
    5.times { b.press(:left, "\e[D") }
    expect(b.cursor).to eq(0)
    b.press(:backspace, "\x7f")
    expect(b.to_s).to eq("ab")
    5.times { b.press(:right, "\e[C") }
    expect(b.cursor).to eq(2)
    b.press(:delete, "\e[3~")
    expect(b.to_s).to eq("ab")
  end

  it "deletes backwards, forwards, by word and by line" do
    b = described_class.new("one two")
    b.press(:ctrl_w, "\x17")
    expect(b.to_s).to eq("one ")
    b.press(:backspace, "\x7f")
    expect(b.to_s).to eq("one")
    b.press(:home, "\e[H")
    b.press(:delete, "\e[3~")
    expect(b.to_s).to eq("ne")
    b.press(:ctrl_k, "\v")
    expect(b.to_s).to eq("")
    "keep this".each_char { |c| b.press(c, c) }
    b.press(:ctrl_u, "\x15")
    expect(b.to_s).to eq("")
  end

  it "keeps whole emoji together" do
    b = described_class.new("a👍b")
    b.press(:left, "\e[D")
    b.press(:backspace, "\x7f")
    expect(b.to_s).to eq("ab")
  end

  it "hands back keys it has no use for" do
    b = described_class.new
    expect(b.press(:tab, "\t")).to be(false)
    expect(b.press(:escape, "\e")).to be(false)
    expect(b.press("x", "x")).to be(true)
  end

  it "scrolls a single row to keep the cursor in view" do
    b = described_class.new("abcdefgh")
    expect(b.row(4, cursor: mark)).to eq("fgh[ ]")
    5.times { b.press(:left, "\e[D") }
    expect(b.row(4, cursor: mark)).to eq("abc[d]")
    expect(b.row(4)).to eq("abc…")
  end

  it "wraps a multi-line view and marks the cursor's row" do
    b = described_class.new("hello world\nbye")
    rows, hidden = b.view(6, 3, cursor: mark)
    expect(rows).to eq(["hello ", "world", "bye[ ]"])
    expect(hidden).to eq(0)
  end

  it "follows the cursor up out of the visible window" do
    b = described_class.new((0..4).map { |i| "line#{i}" }.join("\n"))
    rows, hidden = b.view(10, 2, cursor: mark)
    expect(rows).to eq(["line3", "line4[ ]"])
    expect(hidden).to eq(3)
    18.times { b.press(:left, "\e[D") }
    rows, hidden = b.view(10, 2, cursor: mark)
    expect(rows).to eq(["line1[ ]", "line2"])
    expect(hidden).to eq(1)
    b.press(:left, "\e[D")
    rows, = b.view(10, 2, cursor: mark)
    expect(rows).to eq(["line[1]", "line2"])
  end

  it "gives the cursor a row of its own at the right margin" do
    b = described_class.new("abcd")
    rows, = b.view(4, 3, cursor: mark)
    expect(rows).to eq(["abcd", "[ ]"])
  end

  context "with an image attached" do
    let(:chip) { ->(cell) { "<#{cell}>" } }

    it "shows the image as a numbered token and hands its path back" do
      b = described_class.new("see ")
      b.attach("/tmp/a.png")
      " and ".each_char { |c| b.press(c, c) }
      b.attach("/tmp/b.png")
      expect(b.to_s).to eq("see [Image #1] and [Image #2]")
      expect(b.chips.map(&:path)).to eq(["/tmp/a.png", "/tmp/b.png"])
      expect(b.expand { |c| "@#{c.path}" }).to eq("see @/tmp/a.png and @/tmp/b.png")
    end

    it "moves over and deletes the token as one cell" do
      b = described_class.new("a")
      b.attach("/tmp/a.png")
      "b".each_char { |c| b.press(c, c) }
      2.times { b.press(:left, "\e[D") }
      expect(b.cursor).to eq(1)
      b.press(:delete, "\e[3~")
      expect(b.to_s).to eq("ab")
      b.attach("/tmp/c.png")
      expect(b.to_s).to eq("a[Image #2]b")
      b.press(:backspace, "\x7f")
      expect(b.to_s).to eq("ab")
    end

    it "keeps numbering past a deleted image" do
      b = described_class.new
      b.attach("/tmp/a.png")
      b.press(:backspace, "\x7f")
      b.attach("/tmp/b.png")
      expect(b.to_s).to eq("[Image #2]")
    end

    it "wraps the token whole and paints it, the cursor over all of it" do
      b = described_class.new("look ")
      b.attach("/tmp/a.png")
      b.press(:left, "\e[D")
      rows, = b.view(12, 3, cursor: mark, chip: chip)
      expect(rows).to eq(["look ", "[<[Image #1]>]"])
      rows, = b.view(12, 3, chip: chip)
      expect(rows).to eq(["look ", "<[Image #1]>"])
    end
  end
end
