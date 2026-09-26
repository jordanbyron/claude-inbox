# frozen_string_literal: true

require_relative "../lib/claude_inbox/remote/listener"

Text = ClaudeInbox::Text

RSpec.describe Text do
  it "truncates by display width, not characters" do
    expect(Text.truncate("ab🎉cd", 3)).to eq("ab…")
    expect(Text.truncate("ab🎉cdef", 5)).to eq("ab🎉…")
    expect(Text.truncate("abc", 3)).to eq("abc")
  end

  it "drops leading columns by display width" do
    expect(Text.drop("ab🎉cd", 2)).to eq("🎉cd")
    expect(Text.drop("ab🎉cd", 3)).to eq("cd")
  end

  it "pads ignoring ANSI" do
    s = "\e[31mred\e[0m"
    expect(Text.width(s + "  ")).to eq(5)
    expect(Text.pad(s, 5)).to eq(s + "  ")
  end

  it "wraps on display width" do
    expect(Text.wrap("the quick brown fox", 9)).to eq(["the quick", "brown fox"])
    expect(Text.wrap("abcdefghij", 4)).to eq(%w[abcd efgh ij])
    expect(Text.wrap("short", 10)).to eq(["short"])
  end

  it "humanises ages" do
    expect(Text.age(45)).to eq("45s")
    expect(Text.age(12 * 60 + 5)).to eq("12m")
    expect(Text.age(3 * 3600)).to eq("3h")
    expect(Text.age(2 * 86_400 + 5)).to eq("2d")
  end
end

RSpec.describe ClaudeInbox::Renderer do
  let(:now) { Time.at(1_789_604_500) }
  let(:sessions) { fixture_sessions }
  let(:sections) { Store.sectionize(sessions, Store.merge_entries({}, sessions, now), now) }
  let(:renderer) { ClaudeInbox::Renderer.new(color: false, home: "/Users/byron") }

  def view(width: 80, height: 24, **o) = ClaudeInbox::Renderer::View.new(width: width, height: height, now: now, **o)

  def frame(sec = sections, **o) = renderer.frame(sec, view(**o))

  it "makes every line exactly width wide" do
    f = frame(selected: "f23c8673")
    expect(f.lines.size).to eq(24)
    f.lines.each { |l| expect(Text.width(l)).to eq(80) }
  end

  it "leaves one column between a row's project and the right edge, like the header and section rules" do
    rows = frame(selected: "f23c8673").lines.grep(/  (comma3|claude-inbox|parks_genie) *$/)
    expect(rows).not_to be_empty
    rows.each { |l| expect(l).to match(/\S $/) }
  end

  it "matches the snapshot" do
    f = frame(sections, width: 72, height: 20, selected: "f23c8673")
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
    expect(f.lines).to eq(expected)
  end

  it "selects interactive rows by session uuid, with no PR-less session settling on its own" do
    expect(frame.items.compact.map(&:key)).to eq(
      %w[f23c8673 4a93393d-1c06-57da-9fb8-12f5b1535d95 823b882f dcbc1d98 b0b18338 fbf5253a b03695b1]
    )
  end

  it "puts the session's own line under a row, and the path under one with nothing to say" do
    job = ClaudeInbox::JobState.new("detail" => "watching CI", "needs" => "confirm: merge once green? " + "x" * 80)
    blocked = session(id: "aaa11111", state: "blocked", job_state: job, cwd: "/Users/byron/code/x")
    quiet = session(id: "bbb22222", state: "working", job_state: nil, cwd: "/Users/byron/code/y")
    sec = Store.sectionize([blocked, quiet], {}, now)
    lines = frame(sec, width: 60, height: 12).lines
    expect(lines).to include("       ↳ confirm: merge once green? xxxxxxxxxxxxxxxxxxxxxx…".ljust(60))
    expect(lines).to include("       ↳ ~/code/y".ljust(60))
  end

  it "badges remote sessions and counts them in the header" do
    r = session(id: nil, kind: "interactive", state: nil, status: "idle", session_id: "u9", name: "web", origin: :remote)
    sec = Store.sectionize([r], {}, now)
    text = frame(sec, width: 90, height: 12).lines.join("\n")
    expect(text).to match(/✓ web\s+done · remote/)
    expect(text).to include("⇅ 1 remote")
  end

  it "marks a background session with Remote Control on, and only that one" do
    rc = session(state: "done", job_state: ClaudeInbox::JobState.new("respawnFlags" => ["--remote-control"]))
    plain = session(id: "def45678", name: "other", state: "done", job_state: ClaudeInbox::JobState.new("bridgeSessionId" => "cse_01AB"))
    sec = Store.sectionize([rc, plain], {}, now)
    text = frame(sec, width: 90, height: 12).lines.join("\n")
    expect(text).to match(/✓ thing\s+done ⇅/)
    expect(text).not_to match(/✓ other\s+done ⇅/)
  end

  it "separates an agent that is thinking from one waiting on what it started" do
    thinking = ClaudeInbox::JobState.new("tempo" => "active", "inFlight" => {"tasks" => 2},
      "fan" => [{"kind" => "in_process_teammate"}, {"kind" => "in_process_teammate"}])
    waiting = ClaudeInbox::JobState.new("tempo" => "idle", "inFlight" => {"tasks" => 1},
      "fan" => [{"kind" => "local_bash"}])
    rows = [session(id: "t1", name: "thinking", job_state: thinking), session(id: "t2", name: "watching", job_state: waiting)]
    sec = Store.sectionize(rows, Store.merge_entries({}, rows, now), now)
    text = frame(sec, width: 90, height: 12, tick: 0).lines.join("\n")
    expect(text).to match(/⠋ thinking\s+working · 2 agents/)
    expect(text).to match(/◌ watching\s+idle · 1 shell/)
    expect(text).to match(/✻ 1 working.*◌ 1 idle/)
  end

  it "renders an idle terminal as done and a waiting one as needing you" do
    idle = session(id: nil, kind: "interactive", state: nil, status: "idle", session_id: "u1", name: "shell")
    waiting = session(id: nil, kind: "interactive", state: nil, status: "waiting", waiting_for: "permission prompt", session_id: "u2", name: "shell2")
    sec = Store.sectionize([idle, waiting], {}, now)
    expect(sec.needs_you.map(&:key)).to eq(%w[u2])
    expect(sec.active.map(&:key)).to eq(%w[u1])
    text = frame(sec, width: 90, height: 12).lines.join("\n")
    expect(text).to match(/✓ shell\s+done · your terminal/)
    expect(text).to match(/● shell2\s+needs you: permission prompt · your terminal/)
  end

  it "lists settled rows when expanded" do
    f = frame(sections, width: 80, height: 30, expanded: {settled: true})
    expect(f.items.compact.map(&:key)).to eq(["f23c8673", "4a93393d-1c06-57da-9fb8-12f5b1535d95", "823b882f", "dcbc1d98", "b0b18338", "fbf5253a", "b03695b1"])
    expect(f.lines.join("\n")).to match(/app store release strategy\s+done · 18d/)
  end

  it "lists snoozed rows when expanded, and folds them by default" do
    entries = {"823b882f" => {"wake_at" => now.to_i + 900, "snoozed_at" => now.to_i}}
    snoozed_sections = Store.sectionize(sessions, Store.merge_entries(entries, sessions, now), now)

    folded = frame(snoozed_sections, width: 80, height: 30)
    expect(folded.items.compact.map(&:key)).to include(:snoozed)
    expect(folded.lines.join("\n")).to match(/… 1 snoozed/)

    expanded = frame(snoozed_sections, width: 80, height: 30, expanded: {snoozed: true})
    expect(expanded.items.compact.map(&:key)).to include("823b882f")
  end

  it "truncates long emoji names instead of slicing" do
    sec = Store.sectionize([session(id: "z", name: "🎉" * 60)], {}, now)
    f = frame(sec, width: 60, height: 10)
    f.lines.each { |l| expect(Text.width(l)).to eq(60) }
    expect(f.lines[3]).to include("…")
  end

  it "scrolls to keep the selection visible" do
    sess = (1..30).map { |i| session(id: "s#{i}", name: "n#{i}", started_at: now - i) }
    f = frame(Store.sectionize(sess, {}, now), width: 60, height: 12, selected: "s30", top: 0)
    expect(f.items.compact.map(&:key)).to include("s30")
    expect(f.top).to be > 0
  end

  it "splits the frame for the peek pane" do
    f = frame(sections, width: 100, height: 12, selected: "f23c8673", peek: ClaudeInbox::Peek::View.new(["line one", "line two"], "t"))
    f.lines.each { |l| expect(Text.width(l)).to eq(100) }
    expect(f.lines[1]).to match(/│/)
    expect(f.lines.join("\n")).to include("line two")
  end

  it "overlays a modal in the centre without ellipses" do
    f = frame(sections, width: 60, height: 12, modal: ["┌──┐", "│hi│", "└──┘"])
    f.lines.each { |l| expect(Text.width(l)).to eq(60) }
    expect(f.lines[5]).to include("│hi│")
    expect(f.lines[5]).not_to include("…")
  end

  it "falls back to compact header chips when narrow, full when wide" do
    expect(frame(sections, width: 100, height: 10).lines.first).to include("1 needs you")
    expect(frame(sections, width: 60, height: 10).lines.first).to include("● 1  ✻ 1")
  end

  it "shows the listener in the header: its port, red when it couldn't listen, nothing when off" do
    snapshot = ->(state, lan: false) {
      ClaudeInbox::Remote::Listener::Snapshot.new(state: state, port: 7433, lan: lan, urls: nil, firewall: nil, allowed_modes: [],
        recent: [], held_by: nil, fixture: false)
    }
    header = ->(listening, width: 120) { frame(sections, width: width, height: 10, listening: listening).lines.first }
    expect(header.call(snapshot.call(:listening))).to match(/1 needs you  ·  .*  ·  ◉ :7433/)
    expect(header.call(snapshot.call(:listening, lan: true))).to include("◉ lan:7433")
    expect(header.call(snapshot.call(:in_use))).to include("◉ !")
    expect(header.call(snapshot.call(:held))).to include("◉ !")
    expect(header.call(snapshot.call(:failed))).to include("◉ !")
    expect(header.call(snapshot.call(:off))).not_to include("◉")
    expect(header.call(nil)).not_to include("◉")
    expect(header.call(snapshot.call(:listening), width: 60)).to include("● 1  ✻ 1  ○ 1  ◉ :7433")

    colored = ClaudeInbox::Renderer.new(color: true, home: "/Users/byron")
    chip = ->(state) { colored.frame(sections, view(width: 140, height: 10, listening: snapshot.call(state))).lines.first }
    expect(chip.call(:listening)).to include("\e[38;5;#{ClaudeInbox::Theme::HUES[:blue]}m◉ :7433")
    expect(chip.call(:held)).to include("\e[38;5;#{ClaudeInbox::Theme::HUES[:red]}m◉ !")
  end

  it "puts N in the footer only while listening on the LAN" do
    snapshot = ->(lan) {
      ClaudeInbox::Remote::Listener::Snapshot.new(state: :listening, port: 7433, lan: lan, urls: nil, firewall: nil, allowed_modes: [],
        recent: [], held_by: nil, fixture: false)
    }
    footer = ->(listening) { frame(sections, width: 200, height: 10, listening: listening).lines.last }
    expect(footer.call(snapshot.call(true))).to include("n new  N pair  t pin")
    expect(footer.call(snapshot.call(false))).not_to include("N pair")
    expect(footer.call(nil)).not_to include("N pair")
  end

  it "keeps the header's settled chip distinct from the chip separator" do
    entries = {"823b882f" => {"settled_at" => now.to_i, "last_state" => "done", "state_since" => now.to_i - 5}}
    sec = Store.sectionize(sessions, Store.merge_entries(entries, sessions, now), now)
    header = frame(sec, width: 140, height: 10).lines.first
    expect(header).to match(/·  ◦ \d+ settled/)
    expect(header).not_to match(/·\s+·/)
  end

  it "spins the working glyph with the tick" do
    sec = Store.sectionize([session(id: "w", state: "working")], {}, now)
    a = frame(sec, width: 60, height: 10, tick: 0).lines[3]
    b = frame(sec, width: 60, height: 10, tick: 1).lines[3]
    expect(a).not_to eq(b)
    expect(a).to include(ClaudeInbox::Renderer::SPINNER[0])
  end

  it "renders an empty state" do
    sec = Store.sectionize([], {}, now)
    f = frame(sec, width: 60, height: 10)
    expect(f.lines.join("\n")).to include("Nothing running.")
    expect(f.items.compact).to be_empty
  end

  # Until the first poll lands "nothing running" would be a guess, so the
  # loading screen shows neither that nor the chips. Short waits are blank;
  # long ones get the spinner and a quip; very long ones a hint.
  it "waits quietly for the first poll, then keeps the user company" do
    sec = Store.sectionize([], {}, now)
    quick = frame(sec, width: 60, height: 12, loading: 0.4, tick: 0, status: "polling…")
    expect(quick.lines.join("\n")).not_to include("Nothing running.")
    expect(quick.lines.join("\n")).not_to include("nothing running")
    expect(quick.lines[1..-2].map(&:strip).join).to eq("")
    expect(quick.items.compact).to be_empty

    slow = frame(sec, width: 60, height: 12, loading: 3.2, tick: 0, status: "polling…")
    text = slow.lines.join("\n")
    expect(text).to include(ClaudeInbox::Renderer::SPINNER[0])
    expect(text).to include(ClaudeInbox::Renderer::QUIPS[0])
    expect(text).to include("waiting on claude agents · 3s")
    expect(text).not_to include("claude daemon status")
    later = frame(sec, width: 60, height: 12, loading: 3.2, tick: 7, status: "polling…").lines.join("\n")
    expect(later).to include(ClaudeInbox::Renderer::QUIPS[1])
    expect(later).not_to eq(text)

    stuck = frame(sec, width: 60, height: 12, loading: 12, tick: 0, status: "polling…").lines.join("\n")
    expect(stuck).to include("claude daemon status")
  end

  it "ends the header with a usage bar per window, after any notice, and with nothing when there is none" do
    header = ->(**o) { frame(sections, width: 120, height: 10, **o).lines.first }
    five = ClaudeInbox::RateLimits::Window.new("session", 24)
    seven = ClaudeInbox::RateLimits::Window.new("week", 100)
    expect(header.call(usage: [five, seven])).to match(/session ██░░░░░░░░ 24%  week ██████████ 100% $/)
    expect(header.call(status: "⚠ daemon down", usage: [five])).to match(/⚠ daemon down  ·  session ██░░░░░░░░ 24% $/)
    expect(header.call).not_to include("session")
    expect(header.call).to include("1 needs you")
  end

  it "says how long until each usage window resets, and nothing once it has" do
    header = ->(**o) { frame(sections, width: 120, height: 10, **o).lines.first }
    five = ClaudeInbox::RateLimits::Window.new("session", 24, now + 3 * 3600 + 60)
    seven = ClaudeInbox::RateLimits::Window.new("week", 41, now + 2 * 86_400 + 3600)
    expect(header.call(usage: [five, seven])).to match(/session ██░░░░░░░░ 24% · 3h left  week ████░░░░░░ 41% · 2d left $/)
    past = ClaudeInbox::RateLimits::Window.new("session", 24, now - 60)
    expect(header.call(usage: [past])).to match(/session ██░░░░░░░░ 24% $/)
  end

  it "sheds the usage reset times, then the meters, then cuts the notice to keep the header on one line" do
    usage = [ClaudeInbox::RateLimits::Window.new("session", 0, now + 4 * 3600), ClaudeInbox::RateLimits::Window.new("week", 53, now + 4 * 3600)]
    notice = "settled — u brings it back"
    header = ->(width) { frame(sections, width: width, height: 10, status: notice, usage: usage).lines.first }
    expect(header.call(140)).to match(/#{notice}  ·  session ░+ 0% · 4h left  week █+░+ 53% · 4h left $/o)
    expect(header.call(100)).to match(/\A ▌ claude-inbox .*#{notice}  ·  session ░+ 0%  week █+░+ 53% $/o)
    expect(header.call(60)).to match(/\A ▌ claude-inbox .*#{notice} $/o)
    expect(header.call(30)).to match(/\A ▌ claude-inbox   settled — … $/)
    [140, 100, 60, 30, 16, 5].each { |w| expect(Text.width(header.call(w))).to eq(w) }
  end
end

RSpec.describe "renderer session colors" do
  let(:now) { Time.at(1_789_604_500) }
  let(:renderer) { ClaudeInbox::Renderer.new(color: true, home: "/Users/byron") }
  let(:orange) { "\e[38;5;208m" }

  def frame(sec, **o) = renderer.frame(sec, ClaudeInbox::Renderer::View.new(now: now, **o))

  def colored(name, **attrs)
    session(id: "z", name: "tinted", job_state: ClaudeInbox::JobState.new("color" => name), **attrs)
  end

  def line_for(session, entries = {}, **opts)
    sec = Store.sectionize([session], Store.merge_entries(entries, [session], now), now)
    frame(sec, width: 80, height: 14, **opts).lines.find { |l| l.include?(session.name) }
  end

  it "paints the label of a session /color gave a color" do
    expect(line_for(colored("orange"))).to include("#{orange}tinted")
  end

  it "leaves a session with no color exactly as it was" do
    expect(line_for(session(id: "z", name: "plain"))).not_to match(/\e\[38;5;(208|205)mplain/)
  end

  it "keeps the glyph in the state's color while the label takes the session's" do
    line = line_for(colored("green", state: "blocked"))
    expect(line).to include("\e[38;5;203;1m●")
    expect(line).to include("\e[38;5;203;1mneeds you")
    expect(line).to include("\e[32mtinted\e[39m")
  end

  it "dims a settled row instead of coloring it" do
    s = colored("orange", state: "done")
    line = line_for(s, {"z" => {"settled_at" => now.to_i}}, expanded: {settled: true})
    expect(line).not_to include(orange)
    expect(line).to include("\e[2m")
  end

  it "colors a PR badge by its state and dims a draft or an unknown one" do
    badge = ->(state) { line_for(session(id: "z", name: "shipit", prs: [ClaudeInbox::PullRequest.new(number: 7, state: state)])) }
    expect(badge.call("OPEN")).to include("\e[38;5;108m#7 open\e[0m")
    expect(badge.call("DRAFT")).to include("\e[2m#7 draft\e[0m")
    expect(badge.call("MERGED")).to include("\e[38;5;176m#7 merged\e[0m")
    expect(badge.call("CLOSED")).to include("\e[38;5;203m#7 closed\e[0m")
    expect(badge.call(nil)).to include("\e[2m#7\e[0m")
  end

  it "still pads a colored row to exactly the frame width" do
    sec = Store.sectionize([colored("pink")], {}, now)
    frame(sec, width: 64, height: 12).lines.each { |l| expect(Text.width(l)).to eq(64) }
  end

  it "turns a usage bar yellow from 70% and red from 90%" do
    bar = ->(pct) { frame(Store.sectionize([], {}, now), width: 100, height: 5, usage: [ClaudeInbox::RateLimits::Window.new("session", pct)]).lines.first }
    expect(bar.call(69)).to include("\e[38;5;108m██████░░░░")
    expect(bar.call(70)).to include("\e[38;5;179m███████░░░")
    expect(bar.call(90)).to include("\e[38;5;203m█████████░")
  end
end
