# frozen_string_literal: true

RSpec.describe ClaudeInbox::Renderer do
  subject(:frame) { renderer.frame(sections, view) }

  let(:now) { Time.at(1_789_604_500) }
  let(:sessions) { fixture_sessions }
  let(:entries) { {} }
  let(:sections) { ClaudeInbox::Store.sectionize(sessions, ClaudeInbox::Store.merge_entries(entries, sessions, now), now) }
  let(:renderer) { described_class.new(color: false, home: "/Users/byron") }
  let(:width) { 80 }
  let(:height) { 24 }
  let(:options) { {} }
  let(:view) { described_class::View.new(width: width, height: height, now: now, **options) }
  let(:text) { frame.lines.join("\n") }
  let(:header) { frame.lines.first }

  context "with the fixture's first row selected" do
    let(:options) { {selected: "f23c8673"} }

    it "makes every line exactly width wide" do
      expect(frame.lines.size).to eq(24)
      frame.lines.each { |l| expect(ClaudeInbox::Text.width(l)).to eq(80) }
    end

    it "leaves one column between a row's project and the right edge, like the header and section rules" do
      rows = frame.lines.grep(/  (comma3|claude-inbox|parks_genie) *$/)
      expect(rows).not_to be_empty
      rows.each { |l| expect(l).to match(/\S $/) }
    end

    context "at 72 by 20" do
      let(:width) { 72 }
      let(:height) { 20 }

      it "matches the snapshot" do
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
        expect(frame.lines).to eq(expected)
      end
    end
  end

  it "selects interactive rows by session uuid, with no PR-less session settling on its own" do
    expect(frame.items.compact.map(&:key)).to eq(
      %w[f23c8673 4a93393d-1c06-57da-9fb8-12f5b1535d95 823b882f dcbc1d98 b0b18338 fbf5253a b03695b1]
    )
  end

  context "with a blocked session and a quiet one" do
    let(:sessions) do
      job = ClaudeInbox::JobState.new("detail" => "watching CI", "needs" => "confirm: merge once green? " + "x" * 80)
      [
        session(id: "aaa11111", state: "blocked", job_state: job, cwd: "/Users/byron/code/x"),
        session(id: "bbb22222", state: "working", job_state: nil, cwd: "/Users/byron/code/y")
      ]
    end
    let(:width) { 60 }
    let(:height) { 12 }

    it "puts the session's own line under a row, and the path under one with nothing to say" do
      expect(frame.lines).to include("       ↳ confirm: merge once green? xxxxxxxxxxxxxxxxxxxxxx…".ljust(60))
      expect(frame.lines).to include("       ↳ ~/code/y".ljust(60))
    end
  end

  context "at 90 by 12" do
    let(:width) { 90 }
    let(:height) { 12 }

    context "with a remote session" do
      let(:sessions) { [session(id: nil, kind: "interactive", state: nil, status: "idle", session_id: "u9", name: "web", origin: :remote)] }

      it "badges remote sessions and counts them in the header" do
        expect(text).to match(/✓ web\s+done · remote/)
        expect(text).to include("⇅ 1 remote")
      end
    end

    context "with one background session under Remote Control" do
      let(:sessions) do
        [
          session(state: "done", job_state: ClaudeInbox::JobState.new("respawnFlags" => ["--remote-control"])),
          session(id: "def45678", name: "other", state: "done", job_state: ClaudeInbox::JobState.new("bridgeSessionId" => "cse_01AB"))
        ]
      end

      it "marks a background session with Remote Control on, and only that one" do
        expect(text).to match(/✓ thing\s+done ⇅/)
        expect(text).not_to match(/✓ other\s+done ⇅/)
      end
    end

    context "with one agent thinking and one waiting on a shell" do
      let(:sessions) do
        thinking = ClaudeInbox::JobState.new("tempo" => "active", "inFlight" => {"tasks" => 2},
          "fan" => [{"kind" => "in_process_teammate"}, {"kind" => "in_process_teammate"}])
        waiting = ClaudeInbox::JobState.new("tempo" => "idle", "inFlight" => {"tasks" => 1},
          "fan" => [{"kind" => "local_bash"}])
        [session(id: "t1", name: "thinking", job_state: thinking), session(id: "t2", name: "watching", job_state: waiting)]
      end
      let(:options) { {tick: 0} }

      it "separates an agent that is thinking from one waiting on what it started" do
        expect(text).to match(/⠋ thinking\s+working · 2 agents/)
        expect(text).to match(/◌ watching\s+idle · 1 shell/)
        expect(text).to match(/✻ 1 working.*◌ 1 idle/)
      end
    end

    context "with an idle terminal and a waiting one" do
      let(:sessions) do
        [
          session(id: nil, kind: "interactive", state: nil, status: "idle", session_id: "u1", name: "shell"),
          session(id: nil, kind: "interactive", state: nil, status: "waiting", waiting_for: "permission prompt", session_id: "u2", name: "shell2")
        ]
      end

      it "renders an idle terminal as done and a waiting one as needing you" do
        expect(sections.needs_you.map(&:key)).to eq(%w[u2])
        expect(sections.active.map(&:key)).to eq(%w[u1])
        expect(text).to match(/✓ shell\s+done · your terminal/)
        expect(text).to match(/● shell2\s+needs you: permission prompt · your terminal/)
      end
    end
  end

  context "at 80 by 30" do
    let(:height) { 30 }

    context "with settled rows expanded" do
      let(:options) { {expanded: {settled: true}} }

      it "lists settled rows when expanded" do
        expect(frame.items.compact.map(&:key)).to eq(["f23c8673", "4a93393d-1c06-57da-9fb8-12f5b1535d95", "823b882f", "dcbc1d98", "b0b18338", "fbf5253a", "b03695b1"])
        expect(text).to match(/app store release strategy\s+done · 18d/)
      end
    end

    context "with a snoozed row" do
      let(:entries) { {"823b882f" => {"wake_at" => now.to_i + 900, "snoozed_at" => now.to_i}} }

      it "lists snoozed rows when expanded, and folds them by default" do
        expect(frame.items.compact.map(&:key)).to include(:snoozed)
        expect(text).to match(/… 1 snoozed/)

        expanded = renderer.frame(sections, view.with(expanded: {snoozed: true}))
        expect(expanded.items.compact.map(&:key)).to include("823b882f")
      end
    end
  end

  context "at 60 wide" do
    let(:width) { 60 }
    let(:height) { 10 }

    context "with a long emoji name" do
      let(:sessions) { [session(id: "z", name: "🎉" * 60)] }

      it "truncates long emoji names instead of slicing" do
        frame.lines.each { |l| expect(ClaudeInbox::Text.width(l)).to eq(60) }
        expect(frame.lines[3]).to include("…")
      end
    end

    context "with more rows than fit, the last selected" do
      let(:sessions) { (1..30).map { |i| session(id: "s#{i}", name: "n#{i}", started_at: now - i) } }
      let(:height) { 12 }
      let(:options) { {selected: "s30", top: 0} }

      it "scrolls to keep the selection visible" do
        expect(frame.items.compact.map(&:key)).to include("s30")
        expect(frame.top).to be > 0
      end
    end

    context "with a working session" do
      let(:sessions) { [session(id: "w", state: "working")] }
      let(:options) { {tick: 0} }

      it "spins the working glyph with the tick" do
        next_tick = renderer.frame(sections, view.with(tick: 1)).lines[3]
        expect(frame.lines[3]).not_to eq(next_tick)
        expect(frame.lines[3]).to include(described_class::SPINNER[0])
      end
    end

    context "with nothing running" do
      let(:sessions) { [] }

      it "renders an empty state" do
        expect(text).to include("Nothing running.")
        expect(frame.items.compact).to be_empty
      end
    end

    context "with a modal open" do
      let(:height) { 12 }
      let(:options) { {modal: ["┌──┐", "│hi│", "└──┘"]} }

      it "overlays a modal in the centre without ellipses" do
        frame.lines.each { |l| expect(ClaudeInbox::Text.width(l)).to eq(60) }
        expect(frame.lines[5]).to include("│hi│")
        expect(frame.lines[5]).not_to include("…")
      end
    end
  end

  # Until the first poll lands "nothing running" would be a guess, so the
  # loading screen shows neither that nor the chips. Short waits are blank;
  # long ones get the spinner and a quip; very long ones a hint.
  describe "waiting for the first poll" do
    let(:sessions) { [] }
    let(:width) { 60 }
    let(:height) { 12 }
    let(:options) { {loading: loading, tick: 0, status: "polling…"} }

    context "briefly" do
      let(:loading) { 0.4 }

      it "waits quietly" do
        expect(text).not_to include("Nothing running.")
        expect(text).not_to include("nothing running")
        expect(frame.lines[1..-2].map(&:strip).join).to eq("")
        expect(frame.items.compact).to be_empty
      end
    end

    context "for a few seconds" do
      let(:loading) { 3.2 }

      it "keeps the user company with a spinner and a quip that changes with the tick" do
        expect(text).to include(described_class::SPINNER[0])
        expect(text).to include(described_class::QUIPS[0])
        expect(text).to include("waiting on claude agents · 3s")
        expect(text).not_to include("claude daemon status")
        later = renderer.frame(sections, view.with(tick: 7)).lines.join("\n")
        expect(later).to include(described_class::QUIPS[1])
        expect(later).not_to eq(text)
      end
    end

    context "for long" do
      let(:loading) { 12 }

      it("points at the daemon") { expect(text).to include("claude daemon status") }
    end
  end

  context "with the peek pane open" do
    let(:width) { 100 }
    let(:height) { 12 }
    let(:options) { {selected: "f23c8673", peek: ClaudeInbox::Peek::View.new(["line one", "line two"], "t")} }

    it "splits the frame for the peek pane" do
      frame.lines.each { |l| expect(ClaudeInbox::Text.width(l)).to eq(100) }
      expect(frame.lines[1]).to match(/│/)
      expect(text).to include("line two")
    end
  end

  describe "the header" do
    let(:height) { 10 }

    it "falls back to compact header chips when narrow, full when wide" do
      expect(renderer.frame(sections, view.with(width: 100)).lines.first).to include("1 needs you")
      expect(renderer.frame(sections, view.with(width: 60)).lines.first).to include("● 1  ✻ 1")
    end

    context "with a settled row" do
      let(:width) { 140 }
      let(:entries) { {"823b882f" => {"settled_at" => now.to_i, "last_state" => "done", "state_since" => now.to_i - 5}} }

      it "keeps the header's settled chip distinct from the chip separator" do
        expect(header).to match(/·  ◦ \d+ settled/)
        expect(header).not_to match(/·\s+·/)
      end
    end

    describe "the listener chip" do
      let(:width) { 120 }
      let(:listening) do
        ClaudeInbox::Remote::Listener::Snapshot.new(state: :listening, port: 7433, lan: false, urls: nil, firewall: nil,
          allowed_modes: [], recent: [], held_by: nil, fixture: false)
      end
      let(:options) { {listening: listening} }

      it "shows the port while listening" do
        expect(header).to match(/1 needs you  ·  .*  ·  ◉ :7433/)
        expect(renderer.frame(sections, view.with(width: 60)).lines.first).to include("● 1  ✻ 1  ○ 1  ◉ :7433")
      end

      context "on the LAN" do
        let(:listening) { super().with(lan: true) }

        it("says so") { expect(header).to include("◉ lan:7433") }
      end

      %i[in_use held failed].each do |state|
        context "when #{state}" do
          let(:listening) { super().with(state: state) }

          it("is a red flag that it couldn't listen") { expect(header).to include("◉ !") }
        end
      end

      context "when off" do
        let(:listening) { super().with(state: :off) }

        it("is not there") { expect(header).not_to include("◉") }
      end

      context "with no listener" do
        let(:listening) { nil }

        it("is not there") { expect(header).not_to include("◉") }
      end

      context "in color" do
        let(:renderer) { described_class.new(color: true, home: "/Users/byron") }
        let(:width) { 140 }

        it "is blue while listening and red when it couldn't listen" do
          expect(header).to include("\e[38;5;#{ClaudeInbox::Theme::HUES[:blue]}m◉ :7433")
          held = renderer.frame(sections, view.with(listening: listening.with(state: :held))).lines.first
          expect(held).to include("\e[38;5;#{ClaudeInbox::Theme::HUES[:red]}m◉ !")
        end
      end
    end

    describe "the usage bars" do
      let(:width) { 120 }
      let(:five) { ClaudeInbox::RateLimits::Window.new("session", 24, nil) }
      let(:seven) { ClaudeInbox::RateLimits::Window.new("week", 100, nil) }

      context "with no usage" do
        it "ends with nothing" do
          expect(header).not_to include("session")
          expect(header).to include("1 needs you")
        end
      end

      context "for both windows" do
        let(:options) { {usage: [five, seven]} }

        it("ends the header with a usage bar per window") { expect(header).to match(/session ██░░░░░░░░ 24%  week ██████████ 100% $/) }
      end

      context "after a notice" do
        let(:options) { {status: "⚠ daemon down", usage: [five]} }

        it("puts the bars after the notice") { expect(header).to match(/⚠ daemon down  ·  session ██░░░░░░░░ 24% $/) }
      end

      context "with reset times ahead" do
        let(:five) { ClaudeInbox::RateLimits::Window.new("session", 24, now + 3 * 3600 + 60) }
        let(:seven) { ClaudeInbox::RateLimits::Window.new("week", 41, now + 2 * 86_400 + 3600) }
        let(:options) { {usage: [five, seven]} }

        it "says how long until each usage window resets" do
          expect(header).to match(/session ██░░░░░░░░ 24% · 3h left  week ████░░░░░░ 41% · 2d left $/)
        end
      end

      context "with a reset time passed" do
        let(:options) { {usage: [ClaudeInbox::RateLimits::Window.new("session", 24, now - 60)]} }

        it("says nothing once it has") { expect(header).to match(/session ██░░░░░░░░ 24% $/) }
      end

      describe "beside a notice, as the room shrinks" do
        let(:options) do
          {status: "settled — u brings it back", usage: [
            ClaudeInbox::RateLimits::Window.new("session", 0, now + 4 * 3600),
            ClaudeInbox::RateLimits::Window.new("week", 53, now + 4 * 3600)
          ]}
        end

        {
          140 => /settled — u brings it back  ·  session ░+ 0% · 4h left  week █+░+ 53% · 4h left $/,
          100 => /\A ▌ claude-inbox .*settled — u brings it back  ·  session ░+ 0%  week █+░+ 53% $/,
          60 => /\A ▌ claude-inbox .*settled — u brings it back $/,
          30 => /\A ▌ claude-inbox   settled — … $/,
          16 => nil,
          5 => nil
        }.each do |columns, shape|
          context "at #{columns} wide" do
            let(:width) { columns }

            it "sheds the usage reset times, then the meters, then cuts the notice to keep the header on one line" do
              expect(header).to match(shape) if shape
              expect(ClaudeInbox::Text.width(header)).to eq(columns)
            end
          end
        end
      end
    end
  end

  describe "the footer" do
    let(:width) { 200 }
    let(:height) { 10 }
    let(:footer) { frame.lines.last }
    let(:listening) do
      ClaudeInbox::Remote::Listener::Snapshot.new(state: :listening, port: 7433, lan: true, urls: nil, firewall: nil,
        allowed_modes: [], recent: [], held_by: nil, fixture: false)
    end
    let(:options) { {listening: listening} }

    it("puts N in the footer while listening on the LAN") { expect(footer).to include("n new  N pair  t pin") }

    context "while listening on loopback only" do
      let(:listening) { super().with(lan: false) }

      it("leaves N out") { expect(footer).not_to include("N pair") }
    end

    context "with no listener" do
      let(:listening) { nil }

      it("leaves N out") { expect(footer).not_to include("N pair") }
    end
  end

  describe "session colors" do
    subject(:line) { frame.lines.find { |l| l.include?(sessions.first.name) } }

    let(:renderer) { described_class.new(color: true, home: "/Users/byron") }
    let(:height) { 14 }
    let(:orange) { "\e[38;5;208m" }
    let(:color) { "orange" }
    let(:attrs) { {} }
    let(:sessions) { [session(id: "z", name: "tinted", job_state: ClaudeInbox::JobState.new("color" => color), **attrs)] }

    it("paints the label of a session /color gave a color") { expect(line).to include("#{orange}tinted") }

    context "with no color" do
      let(:sessions) { [session(id: "z", name: "plain")] }

      it("leaves a session with no color exactly as it was") { expect(line).not_to match(/\e\[38;5;(208|205)mplain/) }
    end

    context "on a blocked session" do
      let(:color) { "green" }
      let(:attrs) { {state: "blocked"} }

      it "keeps the glyph in the state's color while the label takes the session's" do
        expect(line).to include("\e[38;5;203;1m●")
        expect(line).to include("\e[38;5;203;1mneeds you")
        expect(line).to include("\e[32mtinted\e[39m")
      end
    end

    context "on a settled row" do
      let(:attrs) { {state: "done"} }
      let(:entries) { {"z" => {"settled_at" => now.to_i}} }
      let(:options) { {expanded: {settled: true}} }

      it "dims a settled row instead of coloring it" do
        expect(line).not_to include(orange)
        expect(line).to include("\e[2m")
      end
    end

    describe "a PR badge" do
      {
        "OPEN" => "\e[38;5;108m#7 open\e[0m",
        "DRAFT" => "\e[2m#7 draft\e[0m",
        "MERGED" => "\e[38;5;176m#7 merged\e[0m",
        "CLOSED" => "\e[38;5;203m#7 closed\e[0m",
        nil => "\e[2m#7\e[0m"
      }.each do |state, badge|
        context "for a #{state || "unknown"} PR" do
          let(:sessions) { [session(id: "z", name: "shipit", prs: [ClaudeInbox::PullRequest.new(number: 7, state: state)])] }

          it("is colored by its state, or dimmed for a draft or an unknown one") { expect(line).to include(badge) }
        end
      end
    end

    context "at 64 by 12" do
      let(:color) { "pink" }
      let(:width) { 64 }
      let(:height) { 12 }

      it "still pads a colored row to exactly the frame width" do
        frame.lines.each { |l| expect(ClaudeInbox::Text.width(l)).to eq(64) }
      end
    end

    describe "a usage bar" do
      let(:width) { 100 }
      let(:height) { 5 }

      {69 => "\e[38;5;108m██████░░░░", 70 => "\e[38;5;179m███████░░░", 90 => "\e[38;5;203m█████████░"}.each do |percent, bar|
        context "at #{percent}%" do
          let(:options) { {usage: [ClaudeInbox::RateLimits::Window.new("session", percent, nil)]} }

          it("turns yellow from 70% and red from 90%") { expect(header).to include(bar) }
        end
      end
    end
  end
end
