# frozen_string_literal: true

require_relative "../lib/claude_inbox/painter"

RSpec.describe ClaudeInbox::Painter do
  it "paints only changed lines" do
    out = StringIO.new
    painter = ClaudeInbox::Painter.new(out)
    painter.paint(%w[a b c])
    out.truncate(0)
    out.rewind
    painter.paint(%w[a X c])
    expect(out.string).to include "X"
    expect(out.string).not_to include "a"
    expect(out.string).to include "\e[2;1H"
  end

  it "never erases to end of line after a row" do
    out = StringIO.new
    ClaudeInbox::Painter.new(out).paint(%w[a b])
    expect(out.string).not_to include "\e[K"
    expect(out.string).not_to include "\e[0K"
  end
end
