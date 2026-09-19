# frozen_string_literal: true

require_relative "test_helper"

Text = ClaudeInbox::Text

describe Text do
  it "truncates by display width, not characters" do
    _(Text.truncate("ab🎉cd", 3)).must_equal "ab…"
    _(Text.truncate("ab🎉cdef", 5)).must_equal "ab🎉…"
    _(Text.truncate("abc", 3)).must_equal "abc"
  end

  it "drops leading columns by display width" do
    _(Text.drop("ab🎉cd", 2)).must_equal "🎉cd"
    _(Text.drop("ab🎉cd", 3)).must_equal "cd"
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

  it "leaves one column between a row's project and the right edge, like the header and section rules" do
    rows = frame(selected: "f23c8673").lines.grep(/  (comma3|claude-inbox|parks_genie) *$/)
    _(rows).wont_be_empty
    rows.each { |l| _(l).must_match(/\S $/) }
  end

  it "matches the snapshot" do
    f = renderer.frame(sections, width: 72, height: 20, now: now, selected: "f23c8673")
    expected = <<-TXT.lines.map { |l| l.chomp.ljust(72) }
 ▌ claude-inbox   ● 1 needs you  ·  ✻ 1 working  ·  ○ 1 terminal

 ▎ NEEDS YOU ─────────────────────────────────────────────────────── 1
 ▶ ● comma3x not booting                         needs you · 0s  comma3 
       ↳ ~/code/comma3

 ▎ ACTIVE ────────────────────────────────────────────────────────── 6
   ⠋ claude-inbox-38         working · your terminal · 0s  claude-inbox 
       ↳ ~/code/claude-inbox
   ✓ comma3x led flashing screen unresponsive  done · idle · 0s  comma3 
       ↳ ~/code/comma3
   ✓ trailforks skill handoff                    done · 9d  parks_genie 
       ↳ ~/code/parks_genie
   ✓ sensor token resilience test               done · 10d  parks_genie 
       ↳ ~/code/parks_genie
   ✓ github milestone review                    done · 17d  parks_genie 
       ↳ ~/code/parks_genie
   ✓ app store release strategy                 done · 18d  parks_genie 
       ↳ ~/code/parks_genie
 j/k move  ⏎ attach  n new  t pin  s snooze  u wake  a alias  o PR  x s…
    TXT
    _(f.lines).must_equal expected
  end

  it "selects interactive rows by session uuid, with no PR-less session settling on its own" do
    _(frame.items.compact.map(&:key)).must_equal(
      %w[f23c8673 4a93393d-1c06-57da-9fb8-12f5b1535d95 823b882f dcbc1d98 b0b18338 fbf5253a b03695b1]
    )
  end

  it "puts the session's own line under a row, and the path under one with nothing to say" do
    job = ClaudeInbox::JobState.new("detail" => "watching CI", "needs" => "confirm: merge once green? " + "x" * 80)
    blocked = session(id: "aaa11111", state: "blocked", job_state: job, cwd: "/Users/byron/code/x")
    quiet = session(id: "bbb22222", state: "working", job_state: nil, cwd: "/Users/byron/code/y")
    sec = Store.sectionize([blocked, quiet], {}, now)
    lines = renderer.frame(sec, width: 60, height: 12, now: now).lines
    _(lines).must_include "       ↳ confirm: merge once green? xxxxxxxxxxxxxxxxxxxxxx…".ljust(60)
    _(lines).must_include "       ↳ ~/code/y".ljust(60)
  end

  it "badges remote sessions and counts them in the header" do
    r = session(id: nil, kind: "interactive", state: nil, status: "idle", session_id: "u9", name: "web", origin: :remote)
    sec = Store.sectionize([r], {}, now)
    text = renderer.frame(sec, width: 90, height: 12, now: now).lines.join("\n")
    _(text).must_match(/✓ web\s+done · remote/)
    _(text).must_include "⇅ 1 remote"
  end

  it "separates an agent that is thinking from one waiting on what it started" do
    thinking = ClaudeInbox::JobState.new("tempo" => "active", "inFlight" => {"tasks" => 2},
      "fan" => [{"kind" => "in_process_teammate"}, {"kind" => "in_process_teammate"}])
    waiting = ClaudeInbox::JobState.new("tempo" => "idle", "inFlight" => {"tasks" => 1},
      "fan" => [{"kind" => "local_bash"}])
    rows = [session(id: "t1", name: "thinking", job_state: thinking), session(id: "t2", name: "watching", job_state: waiting)]
    sec = Store.sectionize(rows, Store.merge_entries({}, rows, now), now)
    text = renderer.frame(sec, width: 90, height: 12, now: now, tick: 0).lines.join("\n")
    _(text).must_match(/⠋ thinking\s+working · 2 agents/)
    _(text).must_match(/◌ watching\s+idle · 1 shell/)
    _(text).must_match(/✻ 1 working.*◌ 1 idle/)
  end

  it "renders an idle terminal as done and a waiting one as needing you" do
    idle = session(id: nil, kind: "interactive", state: nil, status: "idle", session_id: "u1", name: "shell")
    waiting = session(id: nil, kind: "interactive", state: nil, status: "waiting", waiting_for: "permission prompt", session_id: "u2", name: "shell2")
    sec = Store.sectionize([idle, waiting], {}, now)
    _(sec.needs_you.map(&:key)).must_equal %w[u2]
    _(sec.active.map(&:key)).must_equal %w[u1]
    text = renderer.frame(sec, width: 90, height: 12, now: now).lines.join("\n")
    _(text).must_match(/✓ shell\s+done · your terminal/)
    _(text).must_match(/● shell2\s+needs you: permission prompt · your terminal/)
  end

  it "lists settled rows when expanded" do
    f = renderer.frame(sections, width: 80, height: 30, now: now, expanded: {settled: true})
    _(f.items.compact.map(&:key)).must_equal ["f23c8673", "4a93393d-1c06-57da-9fb8-12f5b1535d95", "823b882f", "dcbc1d98", "b0b18338", "fbf5253a", "b03695b1"]
    _(f.lines.join("\n")).must_match(/app store release strategy\s+done · 18d/)
  end

  it "lists snoozed rows when expanded, and folds them by default" do
    entries = {"823b882f" => {"wake_at" => now.to_i + 900, "snoozed_at" => now.to_i}}
    snoozed_sections = Store.sectionize(sessions, Store.merge_entries(entries, sessions, now), now)

    folded = renderer.frame(snoozed_sections, width: 80, height: 30, now: now)
    _(folded.items.compact.map(&:key)).must_include :snoozed
    _(folded.lines.join("\n")).must_match(/… 1 snoozed/)

    expanded = renderer.frame(snoozed_sections, width: 80, height: 30, now: now, expanded: {snoozed: true})
    _(expanded.items.compact.map(&:key)).must_include "823b882f"
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

  it "keeps the header's settled chip distinct from the chip separator" do
    entries = {"823b882f" => {"settled_at" => now.to_i, "last_state" => "done", "state_since" => now.to_i - 5}}
    sec = Store.sectionize(sessions, Store.merge_entries(entries, sessions, now), now)
    header = renderer.frame(sec, width: 140, height: 10, now: now).lines.first
    _(header).must_match(/·  ◦ \d+ settled/)
    _(header).wont_match(/·\s+·/)
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

  # Until the first poll lands "nothing running" would be a guess, so the
  # loading screen shows neither that nor the chips. Short waits are blank;
  # long ones get the spinner and a quip; very long ones a hint.
  it "waits quietly for the first poll, then keeps the user company" do
    sec = Store.sectionize([], {}, now)
    quick = renderer.frame(sec, width: 60, height: 12, now: now, loading: 0.4, tick: 0, status: "polling…")
    _(quick.lines.join("\n")).wont_include "Nothing running."
    _(quick.lines.join("\n")).wont_include "nothing running"
    _(quick.lines[1..-2].map(&:strip).join).must_equal ""
    _(quick.items.compact).must_be_empty

    slow = renderer.frame(sec, width: 60, height: 12, now: now, loading: 3.2, tick: 0, status: "polling…")
    text = slow.lines.join("\n")
    _(text).must_include ClaudeInbox::Renderer::SPINNER[0]
    _(text).must_include ClaudeInbox::Renderer::QUIPS[0]
    _(text).must_include "waiting on claude agents · 3s"
    _(text).wont_include "claude daemon status"
    later = renderer.frame(sec, width: 60, height: 12, now: now, loading: 3.2, tick: 7, status: "polling…").lines.join("\n")
    _(later).must_include ClaudeInbox::Renderer::QUIPS[1]
    _(later).wont_equal text

    stuck = renderer.frame(sec, width: 60, height: 12, now: now, loading: 12, tick: 0, status: "polling…").lines.join("\n")
    _(stuck).must_include "claude daemon status"
  end

  it "ends the header with the usage label, after any notice, and with nothing when there is none" do
    header = ->(**o) { renderer.frame(sections, width: 100, height: 10, now: now, **o).lines.first }
    _(header.call(usage: "usage 5h 24% · 7d 41%")).must_match(/usage 5h 24% · 7d 41% $/)
    _(header.call(status: "⚠ daemon down", usage: "usage 5h 24%")).must_match(/⚠ daemon down  ·  usage 5h 24% $/)
    _(header.call).wont_include "usage"
    _(header.call).must_include "1 needs you"
  end

  it "shows the command line in the footer" do
    _(frame(command: ClaudeInbox::TextBuffer.new("q")).lines.last).must_match(/\A :q +\z/)
  end
end

describe "renderer session colors" do
  let(:now) { Time.at(1_789_604_500) }
  let(:renderer) { ClaudeInbox::Renderer.new(color: true, home: "/Users/byron") }
  let(:orange) { "\e[38;5;208m" }

  def colored(name, **attrs)
    session(id: "z", name: "tinted", job_state: ClaudeInbox::JobState.new("color" => name), **attrs)
  end

  def line_for(session, entries = {}, **opts)
    sec = Store.sectionize([session], Store.merge_entries(entries, [session], now), now)
    renderer.frame(sec, width: 80, height: 14, now: now, **opts).lines.find { |l| l.include?(session.name) }
  end

  it "paints the label of a session /color gave a color" do
    _(line_for(colored("orange"))).must_include "#{orange}tinted"
  end

  it "leaves a session with no color exactly as it was" do
    _(line_for(session(id: "z", name: "plain"))).wont_match(/\e\[38;5;(208|205)mplain/)
  end

  it "keeps the glyph in the state's color while the label takes the session's" do
    line = line_for(colored("green", state: "blocked"))
    _(line).must_include "\e[38;5;203;1m●"
    _(line).must_include "\e[38;5;203;1mneeds you"
    _(line).must_include "\e[32mtinted\e[39m"
  end

  it "dims a settled row instead of coloring it" do
    s = colored("orange", state: "done")
    line = line_for(s, {"z" => {"settled_at" => now.to_i}}, expanded: {settled: true})
    _(line).wont_include orange
    _(line).must_include "\e[2m"
  end

  it "still pads a colored row to exactly the frame width" do
    sec = Store.sectionize([colored("pink")], {}, now)
    renderer.frame(sec, width: 64, height: 12, now: now).lines.each { |l| _(Text.width(l)).must_equal 64 }
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

  it "never erases to end of line after a row" do
    out = StringIO.new
    ClaudeInbox::Painter.new(out).paint(%w[a b], force: true)
    _(out.string).wont_include "\e[K"
    _(out.string).wont_include "\e[0K"
  end
end
