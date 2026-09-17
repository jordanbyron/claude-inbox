# frozen_string_literal: true

require_relative "test_helper"
require "claude_inbox/renderer"

class TextTest < Minitest::Test
  T = ClaudeInbox::Text

  def test_truncate_respects_display_width_of_emoji
    assert_equal "ab…", T.truncate("ab🎉cd", 3)
    assert_equal "ab🎉…", T.truncate("ab🎉cdef", 5)
    assert_equal "abc", T.truncate("abc", 3)
  end

  def test_pad_is_ansi_aware
    s = "\e[31mred\e[0m"
    assert_equal 5, T.width(s + "  ")
    assert_equal s + "  ", T.pad(s, 5)
  end

  def test_age
    assert_equal "45s", T.age(45)
    assert_equal "12m", T.age(12 * 60 + 5)
    assert_equal "3h", T.age(3 * 3600)
    assert_equal "2d", T.age(2 * 86_400 + 5)
  end
end

class RendererTest < Minitest::Test
  include Fixtures

  NOW = Time.at(1_789_604_500)

  def setup
    @sessions = fixture_sessions
    @entries = ClaudeInbox::Store.merge_entries({}, @sessions, NOW)
    @sections = ClaudeInbox::Store.sectionize(@sessions, @entries, NOW)
    @renderer = ClaudeInbox::Renderer.new(color: false)
  end

  def test_every_line_is_exactly_width_wide
    f = @renderer.frame(@sections, width: 80, height: 24, now: NOW, selected: "f23c8673")
    assert_equal 24, f.lines.size
    f.lines.each { |l| assert_equal 80, ClaudeInbox::Text.width(l), l.inspect }
  end

  def test_snapshot
    f = @renderer.frame(@sections, width: 72, height: 20, now: NOW, selected: "f23c8673")
    expected = <<-TXT.lines.map(&:chomp)
 claude-inbox  7 sessions  1 needs you                                  
                                                                        
 Needs you 1                                                            
 ▶ ✽ comma3x not booting                          needs you · 0s  comma3
      /Users/byron/code/comma3                                          
                                                                        
 Working 2                                                              
   ○ claude-inbox-38                             busy · 4m  claude-inbox
   ∙ comma3x led flashing screen unresponsive          done · 0s  comma3
      /Users/byron/code/comma3                                          
                                                                        
 Settled 4                                                              
   … 4 settled                                                          
                                                                        
                                                                        
                                                                        
                                                                        
                                                                        
                                                                        
 ↑↓ move · ⏎ attach · s snooze · u wake · a alias · x stop · ⇥ peek · /…
    TXT
    assert_equal expected, f.lines
  end

  def test_items_skip_interactive_rows_and_include_settled_toggle
    f = @renderer.frame(@sections, width: 80, height: 24, now: NOW)
    keys = f.items.compact.map(&:key)
    assert_equal ["f23c8673", "823b882f", :settled], keys
  end

  def test_settled_expanded_lists_rows_dim
    f = @renderer.frame(@sections, width: 80, height: 30, now: NOW, settled_expanded: true)
    keys = f.items.compact.map(&:key)
    assert_equal ["f23c8673", "823b882f", "dcbc1d98", "b0b18338", "fbf5253a", "b03695b1"], keys
    assert_match(/app store release strategy\s+done 18d/, f.lines.join("\n"))
  end

  def test_long_names_truncate_not_slice
    s = session(id: "z", name: "🎉" * 60, state: "working")
    sec = ClaudeInbox::Store.sectionize([s], {}, NOW)
    f = @renderer.frame(sec, width: 60, height: 10, now: NOW)
    f.lines.each { |l| assert_equal 60, ClaudeInbox::Text.width(l) }
    assert_includes f.lines[3], "…"
  end

  def test_scroll_keeps_selected_visible
    sess = (1..30).map { |i| session(id: "s#{i}", name: "n#{i}", started_at: NOW - i) }
    sec = ClaudeInbox::Store.sectionize(sess, {}, NOW)
    f = @renderer.frame(sec, width: 60, height: 12, now: NOW, selected: "s30", top: 0)
    assert f.items.compact.any? { |item| item.key == "s30" }
    assert f.top > 0
  end

  def test_peek_splits_the_frame
    f = @renderer.frame(@sections, width: 100, height: 12, now: NOW, selected: "f23c8673",
      peek: ["line one", "line two"], peek_title: "comma3x not booting")
    f.lines.each { |l| assert_equal 100, ClaudeInbox::Text.width(l) }
    assert_match(/│/, f.lines[1])
    assert_includes f.lines.join("\n"), "line two"
  end

  def test_modal_overlays_centre
    f = @renderer.frame(@sections, width: 60, height: 12, now: NOW, modal: ["┌──┐", "│hi│", "└──┘"])
    f.lines.each { |l| assert_equal 60, ClaudeInbox::Text.width(l) }
    assert_includes f.lines[5], "│hi│"
    refute_includes f.lines[5], "…"
  end
end

class PainterTest < Minitest::Test
  def test_paints_only_changed_lines
    out = StringIO.new
    painter = ClaudeInbox::Painter.new(out)
    painter.paint(%w[a b c], force: true)
    out.truncate(0)
    out.rewind
    painter.paint(%w[a X c])
    s = out.string
    assert_includes s, "X"
    refute_includes s, "a"
    assert_includes s, "\e[2;1H"
  end
end
