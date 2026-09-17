# frozen_string_literal: true

require_relative "test_helper"
require "claude_inbox/text_buffer"

describe ClaudeInbox::TextBuffer do
  let(:mark) { ->(cell) { "[#{cell}]" } }

  def buffer(text = "")
    ClaudeInbox::TextBuffer.new(text)
  end

  def type(b, str) = str.each_char { |c| b.press(c, c) }

  it "types where the cursor is" do
    b = buffer("ad")
    b.press(:left, "\e[D")
    type(b, "bc")
    _(b.to_s).must_equal "abcd"
    _(b.cursor).must_equal 3
  end

  it "stops at both ends instead of wrapping around" do
    b = buffer("ab")
    5.times { b.press(:left, "\e[D") }
    _(b.cursor).must_equal 0
    b.press(:backspace, "\x7f")
    _(b.to_s).must_equal "ab"
    5.times { b.press(:right, "\e[C") }
    _(b.cursor).must_equal 2
    b.press(:delete, "\e[3~")
    _(b.to_s).must_equal "ab"
  end

  it "deletes backwards, forwards, by word and by line" do
    b = buffer("one two")
    b.press(:ctrl_w, "\x17")
    _(b.to_s).must_equal "one "
    b.press(:backspace, "\x7f")
    _(b.to_s).must_equal "one"
    b.press(:home, "\e[H")
    b.press(:delete, "\e[3~")
    _(b.to_s).must_equal "ne"
    b.press(:ctrl_k, "\v")
    _(b.to_s).must_equal ""
    type(b, "keep this")
    b.press(:ctrl_u, "\x15")
    _(b.to_s).must_equal ""
  end

  it "keeps whole emoji together" do
    b = buffer("a👍b")
    b.press(:left, "\e[D")
    b.press(:backspace, "\x7f")
    _(b.to_s).must_equal "ab"
  end

  it "hands back keys it has no use for" do
    b = buffer
    _(b.press(:tab, "\t")).must_equal false
    _(b.press(:escape, "\e")).must_equal false
    _(b.press("x", "x")).must_equal true
  end

  it "scrolls a single row to keep the cursor in view" do
    b = buffer("abcdefgh")
    _(b.row(4, cursor: mark)).must_equal "fgh[ ]"
    5.times { b.press(:left, "\e[D") }
    _(b.row(4, cursor: mark)).must_equal "abc[d]"
    _(b.row(4)).must_equal "abc…"
  end

  it "wraps a multi-line view and marks the cursor's row" do
    b = buffer("hello world\nbye")
    rows, hidden = b.view(6, 3, cursor: mark)
    _(rows).must_equal ["hello ", "world", "bye[ ]"]
    _(hidden).must_equal 0
  end

  it "follows the cursor up out of the visible window" do
    b = buffer((0..4).map { |i| "line#{i}" }.join("\n"))
    rows, hidden = b.view(10, 2, cursor: mark)
    _(rows).must_equal ["line3", "line4[ ]"]
    _(hidden).must_equal 3
    18.times { b.press(:left, "\e[D") }
    rows, hidden = b.view(10, 2, cursor: mark)
    _(rows).must_equal ["line1[ ]", "line2"]
    _(hidden).must_equal 1
    b.press(:left, "\e[D")
    rows, = b.view(10, 2, cursor: mark)
    _(rows).must_equal ["line[1]", "line2"]
  end

  it "gives the cursor a row of its own at the right margin" do
    b = buffer("abcd")
    rows, = b.view(4, 3, cursor: mark)
    _(rows).must_equal ["abcd", "[ ]"]
  end
end
