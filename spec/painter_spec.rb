# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/claude_inbox/painter"

describe ClaudeInbox::Painter do
  it "paints only changed lines" do
    out = StringIO.new
    painter = ClaudeInbox::Painter.new(out)
    painter.paint(%w[a b c])
    out.truncate(0)
    out.rewind
    painter.paint(%w[a X c])
    _(out.string).must_include "X"
    _(out.string).wont_include "a"
    _(out.string).must_include "\e[2;1H"
  end

  it "never erases to end of line after a row" do
    out = StringIO.new
    ClaudeInbox::Painter.new(out).paint(%w[a b])
    _(out.string).wont_include "\e[K"
    _(out.string).wont_include "\e[0K"
  end
end
