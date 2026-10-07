# frozen_string_literal: true

RSpec.describe ClaudeInbox::Peek do
  subject(:peek) { described_class.new(logs) }

  let(:replay) { (1..10).map { |i| "line #{i}" }.join("\r\n") }
  let(:client) { ClaudeInbox::FixtureClient.new(fixture_path("agents.json"), logs: replay) }
  let(:now) { Time.at(1_789_400_000) }
  let(:clock) { StillClock.new(now) }
  let(:logs) { ClaudeInbox::Logs.new(client, clock: clock) }
  let(:row) { ClaudeInbox::Store::Row.new(session, nil) }
  let(:terminal) { {id: nil, kind: "interactive", state: nil} }

  before { logs.start }
  after { logs.stop }

  it "shows nothing while closed" do
    peek.select(session)
    expect(peek.view(row, 10)).to be_nil
  end

  it "stays closed on a fold, which has no session to show" do
    peek.select(nil)
    peek.toggle
    expect(peek.view(nil, 10)).to be_nil
  end

  it "explains a terminal session instead of fetching its logs" do
    r = ClaudeInbox::Store::Row.new(session(**terminal, status: "idle", session_id: "u1", pid: 42), nil)
    peek.select(r.session)
    peek.toggle
    v = peek.view(r, 10)
    expect(v.lines).to eq([described_class::TERMINAL_NOTE, "", "pid 42 · /tmp/proj", "session u1"])
    expect(v.title).to eq("thing")
    expect(logs.cached("abc12345")).to be_nil
  end

  it "explains a remote session the same way, with its claude.ai/code link" do
    r = ClaudeInbox::Store::Row.new(
      session(**terminal, status: "idle", session_id: "u2", pid: 7, origin: :remote, bridge_id: "cse_01AB"),
      nil
    )
    peek.select(r.session)
    peek.toggle
    expect(peek.view(r, 10).lines.first).to eq(described_class::REMOTE_NOTE)
    expect(peek.view(r, 10).lines.last).to eq("https://claude.ai/code/session_01AB")
  end

  it "says loading until the worker answers, then shows the logs" do
    r = row
    peek.select(r.session)
    peek.toggle
    expect(peek.view(r, 10).lines).to eq(["(loading…)"])

    clock.advance(ClaudeInbox::Logs::DEBOUNCE)
    logs.tick
    expect(wait_for { logs.cached("abc12345") }).not_to be_nil
    expect(peek.view(r, 10).lines).to eq((1..10).map { |i| "line #{i}" })
  end

  it "waits out the debounce before asking" do
    r = row
    peek.select(r.session)
    logs.tick
    expect(logs.cached("abc12345")).to be_nil
  end

  it "scrolls back from the tail and no further than the history allows" do
    r = row
    peek.select(r.session)
    peek.toggle
    clock.advance(ClaudeInbox::Logs::DEBOUNCE)
    logs.tick
    expect(wait_for { logs.cached(r.session.id) }).not_to be_nil
    expect(peek.view(r, 4).lines).to eq((1..10).map { |i| "line #{i}" })

    peek.scroll(2)
    expect(peek.view(r, 4).lines).to eq((1..8).map { |i| "line #{i}" })

    peek.scroll(100)
    expect(peek.view(r, 4).lines).to eq((1..4).map { |i| "line #{i}" })

    peek.scroll(-100)
    expect(peek.view(r, 4).lines).to eq((1..10).map { |i| "line #{i}" })
  end

  it "forgets the scroll on a new selection" do
    r = row
    peek.select(r.session)
    peek.toggle
    clock.advance(ClaudeInbox::Logs::DEBOUNCE)
    logs.tick
    expect(wait_for { logs.cached(r.session.id) }).not_to be_nil
    peek.scroll(3)
    peek.select(r.session)
    expect(peek.view(r, 4).lines).to eq((1..10).map { |i| "line #{i}" })
  end

  it "closes on demand" do
    peek.select(session)
    peek.toggle
    expect(peek.open?).to be(true)
    peek.close
    expect(peek.open?).to be(false)
    expect(peek.view(row, 10)).to be_nil
  end

  it "sums up the session and its pull requests under the title" do
    prs = ["OPEN", nil].map do |state|
      ClaudeInbox::PullRequest.new(number: 7, url: "https://github.com/o/r/pull/7", state: state)
    end
    r = ClaudeInbox::Store::Row.new(session(status: "idle", waiting_for: "permission prompt", prs: prs), nil)
    peek.select(r.session)
    peek.toggle
    started = now.strftime("started %b %-d %H:%M")
    expect(peek.view(r, 10).subtitle).to eq("working · idle · permission prompt · abc12345 · #{started} · #7 open · #7 ?")
  end
end
