# frozen_string_literal: true

require_relative "../lib/claude_inbox/text"

RSpec.describe ClaudeInbox::Text do
  it "prints control characters as \\xNN and bad bytes as U+FFFD, so nothing reaches the terminal as an escape" do
    expect(ClaudeInbox::Text.printable("a\e[2Jb\tc\n")).to eq("a\\x1b[2Jb\\x09c\\x0a")
    expect(ClaudeInbox::Text.printable("x\xFFy".b)).to eq("x\uFFFDy")
    expect(ClaudeInbox::Text.printable(nil)).to eq("")
  end
end
