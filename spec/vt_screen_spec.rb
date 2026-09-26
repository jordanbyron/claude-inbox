# frozen_string_literal: true

RSpec.describe ClaudeInbox::VtScreen do
  subject(:screen) { described_class.new }

  it("handles plain text and CRLF") { expect(screen.feed("hello\r\nworld").lines).to eq(%w[hello world]) }
  it("turns cursor-forward into spaces") { expect(screen.feed("a\e[2Cb").lines).to eq(["a  b"]) }
  it("ignores SGR and OSC") { expect(screen.feed("\e[31mred\e[0m\e]0;title\a text").lines).to eq(["red text"]) }
  it("erases to the start of the line") { expect(screen.feed("abcdef\e[3G\e[1K").lines).to eq(["   def"]) }

  context "three rows high" do
    subject(:screen) { described_class.new(rows: 3, cols: 5) }

    it("scrolls at the bottom") { expect(screen.feed("a\r\nb\r\nc\r\nd").lines).to eq(%w[b c d]) }
  end

  it "positions absolutely and erases to end of line" do
    expect(screen.feed("\e[3;5Hxyz\e[1;1Hfirst\e[3;6H\e[K").lines).to eq(["first", "", "    x"])
  end

  it "gives wide glyphs two cells" do
    expect(screen.feed("🎉x").lines).to eq(["🎉x"])
    expect(described_class.new.feed("🎉\e[4Gx").lines).to eq(["🎉 x"])
  end

  it "turns the captured claude logs replay into readable text" do
    lines = screen.feed(File.binread(fixture_path("logs_raw.txt"))).lines
    text = lines.join("\n")
    expect(text).to include "That's a duplicate completion notice"
    expect(text).to include "sudo xcodebuild -license accept"
    expect(lines.size).to be > 5
  end
end
