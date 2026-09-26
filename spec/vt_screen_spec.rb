# frozen_string_literal: true

RSpec.describe ClaudeInbox::VtScreen do
  def screen(str, **kw) = ClaudeInbox::VtScreen.new(**kw).feed(str)

  it("handles plain text and CRLF") { expect(screen("hello\r\nworld").lines).to eq(%w[hello world]) }
  it("turns cursor-forward into spaces") { expect(screen("a\e[2Cb").lines).to eq(["a  b"]) }
  it("ignores SGR and OSC") { expect(screen("\e[31mred\e[0m\e]0;title\a text").lines).to eq(["red text"]) }
  it("scrolls at the bottom") { expect(screen("a\r\nb\r\nc\r\nd", rows: 3, cols: 5).lines).to eq(%w[b c d]) }
  it("erases to the start of the line") { expect(screen("abcdef\e[3G\e[1K").lines).to eq(["   def"]) }

  it "positions absolutely and erases to end of line" do
    expect(screen("\e[3;5Hxyz\e[1;1Hfirst\e[3;6H\e[K").lines).to eq(["first", "", "    x"])
  end

  it "gives wide glyphs two cells" do
    expect(screen("🎉x").lines).to eq(["🎉x"])
    expect(screen("🎉\e[4Gx").lines).to eq(["🎉 x"])
  end

  it "turns the captured claude logs replay into readable text" do
    lines = screen(File.binread(fixture_path("logs_raw.txt"))).lines
    text = lines.join("\n")
    expect(text).to include "That's a duplicate completion notice"
    expect(text).to include "sudo xcodebuild -license accept"
    expect(lines.size).to be > 5
  end
end
