# frozen_string_literal: true

require_relative "test_helper"

Text = ClaudeInbox::Text

describe Text do
  it "truncates by display width, not characters" do
    _(Text.truncate("ab🎉cd", 3)).must_equal "ab…"
    _(Text.truncate("ab🎉cdef", 5)).must_equal "ab🎉…"
    _(Text.truncate("abc", 3)).must_equal "abc"
  end

  it "pads ignoring ANSI" do
    s = "\e[31mred\e[0m"
    _(Text.width(s + "  ")).must_equal 5
    _(Text.pad(s, 5)).must_equal s + "  "
  end

  it "wraps on display width" do
    _(Text.wrap("the quick brown fox", 9)).must_equal ["the quick", "brown fox"]
    _(Text.wrap("abcdefghij", 4)).must_equal %w[abcd efgh ij]
    _(Text.wrap("short", 10)).must_equal ["short"]
  end

  it "humanises ages" do
    _(Text.age(45)).must_equal "45s"
    _(Text.age(12 * 60 + 5)).must_equal "12m"
    _(Text.age(3 * 3600)).must_equal "3h"
    _(Text.age(2 * 86_400 + 5)).must_equal "2d"
  end
end

describe ClaudeInbox::Renderer do
  let(:now) { Time.at(1_789_604_500) }
  let(:sessions) { fixture_sessions }
  let(:sections) { Store.sectionize(sessions, Store.merge_entries({}, sessions, now), now) }
  let(:renderer) { ClaudeInbox::Renderer.new(color: false, home: "/Users/byron") }

  def frame(**o) = renderer.frame(sections, width: 80, height: 24, now: now, **o)

  it "makes every line exactly width wide" do
    f = frame(selected: "f23c8673")
    _(f.lines.size).must_equal 24
    f.lines.each { |l| _(Text.width(l)).must_equal 80 }
  end

  it "matches the snapshot" do
    f = renderer.frame(sections, width: 72, height: 20, now: now, selected: "f23c8673")
    expected = <<-TXT.lines.map(&:chomp)
 ▌ claude-inbox   ● 1  ✻ 1  ○ 1  ∙ 4                                    
                                                                        
 ▎ NEEDS YOU ─────────────────────────────────────────────────────── 1  
 ▶ ● comma3x not booting                          needs you · 0s  comma3
       ↳ ~/code/comma3                                                  
                                                                        
 ▎ WORKING ───────────────────────────────────────────────────────── 2  
   ⠋ claude-inbox-38          working · your terminal · 0s  claude-inbox
       ↳ ~/code/claude-inbox                                            
   ✓ comma3x led flashing screen unresponsive   done · idle · 0s  comma3
       ↳ ~/code/comma3                                                  
                                                                        
 ▎ SETTLED ───────────────────────────────────────────────────────── 4  
   … 4 settled                                                          
                                                                        
                                                                        
                                                                        
                                                                        
                                                                        
 j/k move  ⏎ attach  s snooze  u wake  a alias  x stop  p peek  ⇥ secti…
    TXT
    _(f.lines).must_equal expected
  end

  it "selects interactive rows by session uuid and includes the settled toggle" do
    _(frame.items.compact.map(&:key)).must_equal ["f23c8673", "4a93393d-1c06-57da-9fb8-12f5b1535d95", "823b882f", :settled]
  end

  it "badges remote sessions and counts them in the header" do
    r = session(id: nil, kind: "interactive", state: nil, status: "idle", session_id: "u9", name: "web", origin: :remote)
    sec = Store.sectionize([r], {}, now)
    text = renderer.frame(sec, width: 90, height: 12, now: now).lines.join("\n")
    _(text).must_match(/✓ web\s+done · remote/)
    _(text).must_include "⇅ 1 remote"
  end

  it "renders an idle terminal as done and a waiting one as needing you" do
    idle = session(id: nil, kind: "interactive", state: nil, status: "idle", session_id: "u1", name: "shell")
    waiting = session(id: nil, kind: "interactive", state: nil, status: "waiting", waiting_for: "permission prompt", session_id: "u2", name: "shell2")
    sec = Store.sectionize([idle, waiting], {}, now)
    _(sec.needs_you.map(&:key)).must_equal %w[u2]
    _(sec.working.map(&:key)).must_equal %w[u1]
    text = renderer.frame(sec, width: 90, height: 12, now: now).lines.join("\n")
    _(text).must_match(/✓ shell\s+done · your terminal/)
    _(text).must_match(/● shell2\s+needs you: permission prompt · your terminal/)
  end

  it "lists settled rows when expanded" do
    f = renderer.frame(sections, width: 80, height: 30, now: now, settled_expanded: true)
    _(f.items.compact.map(&:key)).must_equal ["f23c8673", "4a93393d-1c06-57da-9fb8-12f5b1535d95", "823b882f", "dcbc1d98", "b0b18338", "fbf5253a", "b03695b1"]
    _(f.lines.join("\n")).must_match(/app store release strategy\s+done · 18d/)
  end

  it "truncates long emoji names instead of slicing" do
    sec = Store.sectionize([session(id: "z", name: "🎉" * 60)], {}, now)
    f = renderer.frame(sec, width: 60, height: 10, now: now)
    f.lines.each { |l| _(Text.width(l)).must_equal 60 }
    _(f.lines[3]).must_include "…"
  end

  it "scrolls to keep the selection visible" do
    sess = (1..30).map { |i| session(id: "s#{i}", name: "n#{i}", started_at: now - i) }
    f = renderer.frame(Store.sectionize(sess, {}, now), width: 60, height: 12, now: now, selected: "s30", top: 0)
    _(f.items.compact.map(&:key)).must_include "s30"
    _(f.top).must_be :>, 0
  end

  it "splits the frame for the peek pane" do
    f = renderer.frame(sections, width: 100, height: 12, now: now, selected: "f23c8673", peek: ["line one", "line two"], peek_title: "t")
    f.lines.each { |l| _(Text.width(l)).must_equal 100 }
    _(f.lines[1]).must_match(/│/)
    _(f.lines.join("\n")).must_include "line two"
  end

  it "overlays a modal in the centre without ellipses" do
    f = renderer.frame(sections, width: 60, height: 12, now: now, modal: ["┌──┐", "│hi│", "└──┘"])
    f.lines.each { |l| _(Text.width(l)).must_equal 60 }
    _(f.lines[5]).must_include "│hi│"
    _(f.lines[5]).wont_include "…"
  end

  it "falls back to compact header chips when narrow, full when wide" do
    _(renderer.frame(sections, width: 100, height: 10, now: now).lines.first).must_include "1 needs you"
    _(renderer.frame(sections, width: 60, height: 10, now: now).lines.first).must_include "● 1  ✻ 1"
  end

  it "spins the working glyph with the tick" do
    sec = Store.sectionize([session(id: "w", state: "working")], {}, now)
    a = renderer.frame(sec, width: 60, height: 10, now: now, tick: 0).lines[3]
    b = renderer.frame(sec, width: 60, height: 10, now: now, tick: 1).lines[3]
    _(a).wont_equal b
    _(a).must_include ClaudeInbox::Renderer::SPINNER[0]
  end

  it "renders an empty state" do
    sec = Store.sectionize([], {}, now)
    f = renderer.frame(sec, width: 60, height: 10, now: now)
    _(f.lines.join("\n")).must_include "Nothing running."
    _(f.items.compact).must_be_empty
  end

  it "shows the command line in the footer" do
    _(frame(command: "q").lines.last).must_match(/^ :q▏\s+$/)
  end
end

describe ClaudeInbox::Painter do
  it "paints only changed lines" do
    out = StringIO.new
    painter = ClaudeInbox::Painter.new(out)
    painter.paint(%w[a b c], force: true)
    out.truncate(0)
    out.rewind
    painter.paint(%w[a X c])
    _(out.string).must_include "X"
    _(out.string).wont_include "a"
    _(out.string).must_include "\e[2;1H"
  end
end
