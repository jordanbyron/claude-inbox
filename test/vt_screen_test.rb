# frozen_string_literal: true

require_relative "test_helper"
require "claude_inbox/vt_screen"

class VtScreenTest < Minitest::Test
  include Fixtures

  def screen(str, **kw) = ClaudeInbox::VtScreen.new(**kw).feed(str)

  def test_plain_text_and_newlines
    assert_equal ["hello", "world"], screen("hello\r\nworld").lines
  end

  def test_cursor_forward_becomes_spaces
    assert_equal ["a  b"], screen("a\e[2Cb").lines
  end

  def test_absolute_positioning_and_erase_line
    s = screen("\e[3;5Hxyz\e[1;1Hfirst\e[3;6H\e[K")
    assert_equal ["first", "", "    x"], s.lines
  end

  def test_sgr_and_osc_are_ignored
    assert_equal ["red text"], screen("\e[31mred\e[0m\e]0;title\a text").lines
  end

  def test_scrolls_at_bottom
    s = screen("a\r\nb\r\nc\r\nd", rows: 3, cols: 5)
    assert_equal %w[b c d], s.lines
  end

  def test_wide_glyphs_take_two_cells
    assert_equal ["🎉x"], screen("🎉x").lines
    assert_equal ["🎉 x"], screen("🎉\e[4Gx").lines
  end

  def test_fixture_replay_produces_readable_text
    raw = File.binread(fixture_path("logs_raw.txt"))
    lines = screen(raw).lines
    text = lines.join("\n")
    assert_includes text, "That's a duplicate completion notice"
    assert_includes text, "sudo xcodebuild -license accept"
    assert lines.size > 5
  end
end
