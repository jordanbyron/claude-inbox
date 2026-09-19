# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/claude_inbox/logs"
require_relative "../lib/claude_inbox/peek"

describe ClaudeInbox::Peek do
  let(:replay) { (1..10).map { |i| "line #{i}" }.join("\r\n") }
  let(:client) { ClaudeInbox::FixtureClient.new(fixture_path("agents.json"), logs: replay) }
  let(:now) { Time.at(1_789_400_000) }
  let(:clock) { -> { now + @elapsed } }
  let(:logs) { ClaudeInbox::Logs.new(client, clock: clock) }
  let(:peek) { ClaudeInbox::Peek.new(logs) }

  before do
    @elapsed = 0
    logs.start
  end
  after { logs.stop }

  def row(**attrs) = ClaudeInbox::Store::Row.new(session: session(**attrs), entry: nil)

  def on(key) = ClaudeInbox::Store::Selection.row(key)

  def pr(state) = ClaudeInbox::PullRequest.new(number: 7, url: "https://github.com/o/r/pull/7", state: state)

  def fetch(r)
    peek.select(on(r.key), r.session)
    peek.toggle
    @elapsed += ClaudeInbox::Logs::DEBOUNCE
    logs.tick
    _(wait_for { logs.cached(r.session.id) }).wont_be_nil
  end

  it "shows nothing while closed" do
    peek.select(on("abc12345"), session)
    _(peek.view(row, 10)).must_be_nil
  end

  it "shows a placeholder when nothing is selected" do
    peek.select(on("abc12345"), nil)
    peek.toggle
    v = peek.view(nil, 10)
    _(v.lines).must_equal ["(nothing selected)"]
    _(v.title).must_equal "abc12345"
    _(v.subtitle).must_be_nil
  end

  it "stays closed on a fold, which has no session to show" do
    peek.select(ClaudeInbox::Store::Selection.fold(:settled), nil)
    peek.toggle
    _(peek.view(nil, 10)).must_be_nil
  end

  it "explains a terminal session instead of fetching its logs" do
    r = row(id: nil, kind: "interactive", state: nil, status: "idle", session_id: "u1", pid: 42)
    peek.select(on(r.key), r.session)
    peek.toggle
    v = peek.view(r, 10)
    _(v.lines).must_equal [ClaudeInbox::Peek::TERMINAL_NOTE, "", "pid 42 · /tmp/proj", "session u1"]
    _(v.title).must_equal "thing"
    _(logs.cached("abc12345")).must_be_nil
  end

  it "explains a remote session the same way" do
    r = row(id: nil, kind: "interactive", state: nil, status: "idle", session_id: "u2", pid: 7, origin: :remote)
    peek.select(on(r.key), r.session)
    peek.toggle
    _(peek.view(r, 10).lines.first).must_equal ClaudeInbox::Peek::REMOTE_NOTE
  end

  it "says loading until the worker answers, then shows the logs" do
    r = row
    peek.select(on(r.key), r.session)
    peek.toggle
    _(peek.view(r, 10).lines).must_equal ["(loading…)"]

    @elapsed += ClaudeInbox::Logs::DEBOUNCE
    logs.tick
    _(wait_for { logs.cached("abc12345") }).wont_be_nil
    _(peek.view(r, 10).lines).must_equal (1..10).map { |i| "line #{i}" }
  end

  it "waits out the debounce before asking" do
    r = row
    peek.select(on(r.key), r.session)
    logs.tick
    _(logs.cached("abc12345")).must_be_nil
  end

  it "scrolls back from the tail and no further than the history allows" do
    r = row
    fetch(r)
    _(peek.view(r, 6).lines).must_equal (1..10).map { |i| "line #{i}" }

    peek.scroll(2)
    _(peek.view(r, 6).lines).must_equal (1..8).map { |i| "line #{i}" }

    peek.scroll(100)
    _(peek.view(r, 6).lines).must_equal (1..4).map { |i| "line #{i}" }

    peek.scroll(-100)
    _(peek.view(r, 6).lines).must_equal (1..10).map { |i| "line #{i}" }
  end

  it "forgets the scroll on a new selection" do
    r = row
    fetch(r)
    peek.scroll(3)
    peek.select(on(r.key), r.session)
    _(peek.view(r, 6).lines).must_equal (1..10).map { |i| "line #{i}" }
  end

  it "closes on demand" do
    peek.select(on("abc12345"), session)
    peek.toggle
    _(peek.open?).must_equal true
    peek.close
    _(peek.open?).must_equal false
    _(peek.view(row, 10)).must_be_nil
  end

  it "sums up the session and its pull requests under the title" do
    r = row(status: "idle", waiting_for: "permission prompt", prs: [pr("OPEN"), pr(nil)])
    peek.select(on(r.key), r.session)
    peek.toggle
    started = now.strftime("started %b %-d %H:%M")
    _(peek.view(r, 10).subtitle).must_equal "working · idle · permission prompt · abc12345 · #{started} · #7 open · #7 ?"
  end
end
