# frozen_string_literal: true

require_relative "test_helper"

describe ClaudeInbox::VtScreen do
  def screen(str, **kw) = ClaudeInbox::VtScreen.new(**kw).feed(str)

  it("handles plain text and CRLF") { _(screen("hello\r\nworld").lines).must_equal %w[hello world] }
  it("turns cursor-forward into spaces") { _(screen("a\e[2Cb").lines).must_equal ["a  b"] }
  it("ignores SGR and OSC") { _(screen("\e[31mred\e[0m\e]0;title\a text").lines).must_equal ["red text"] }
  it("scrolls at the bottom") { _(screen("a\r\nb\r\nc\r\nd", rows: 3, cols: 5).lines).must_equal %w[b c d] }

  it "positions absolutely and erases to end of line" do
    _(screen("\e[3;5Hxyz\e[1;1Hfirst\e[3;6H\e[K").lines).must_equal ["first", "", "    x"]
  end

  it "gives wide glyphs two cells" do
    _(screen("🎉x").lines).must_equal ["🎉x"]
    _(screen("🎉\e[4Gx").lines).must_equal ["🎉 x"]
  end

  it "turns the captured claude logs replay into readable text" do
    lines = screen(File.binread(fixture_path("logs_raw.txt"))).lines
    text = lines.join("\n")
    _(text).must_include "That's a duplicate completion notice"
    _(text).must_include "sudo xcodebuild -license accept"
    _(lines.size).must_be :>, 5
  end
end
