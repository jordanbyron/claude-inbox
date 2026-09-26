# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/claude_inbox/text"

describe ClaudeInbox::Text do
  it "prints control characters as \\xNN and bad bytes as U+FFFD, so nothing reaches the terminal as an escape" do
    _(ClaudeInbox::Text.printable("a\e[2Jb\tc\n")).must_equal "a\\x1b[2Jb\\x09c\\x0a"
    _(ClaudeInbox::Text.printable("x\xFFy".b)).must_equal "x\uFFFDy"
    _(ClaudeInbox::Text.printable(nil)).must_equal ""
  end
end
