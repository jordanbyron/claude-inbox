# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeInbox::PullRequests do
  let(:now) { Time.at(1_789_600_000) }
  let(:cached) { {cache_path: fixture_path("gh-pr-status-cache.json"), resolved_path: nil, clock: -> { now }} }
  let(:prs) { described_class.new(**cached, gh: nil) }

  it "seeds state from Claude Code's own cache" do
    pr = prs.status("https://github.com/jordanbyron/parks_genie/pull/885")
    expect(pr.number).to eq(885)
    expect(pr.state).to eq("DRAFT")
    expect(pr.short).to eq("#885")
    expect(pr).not_to be_resolved
  end

  it "knows the number but not the state of a PR nobody has cached" do
    pr = prs.status("https://github.com/o/r/pull/42")
    expect(pr.number).to eq(42)
    expect(pr).not_to be_known
  end

  it "enriches sessions, letting an override replace the scanned list" do
    sessions = ClaudeInbox::JobState.enrich(
      [session(id: "b03695b1"), session(id: "b0b18338")],
      jobs_dir: fixture_path("jobs")
    )
    a, b = prs.enrich(sessions, {"b0b18338" => "https://github.com/o/r/pull/1"})
    expect(a.prs.map(&:number)).to eq([856, 866])
    expect(b.prs.map(&:number)).to eq([1])
  end

  it "reads when gh says a PR was merged or closed" do
    json = '{"number":9,"state":"MERGED","isDraft":false,"closedAt":"2026-09-28T14:00:00Z"}'
    expect(described_class.parse("u", json).resolved_at).to eq(Time.utc(2026, 9, 28, 14).to_i)
    expect(described_class.parse("u", '{"state":"OPEN","isDraft":false,"closedAt":null}').resolved_at).to be_nil
  end

  it "parses gh output, calling an open draft DRAFT" do
    pr = described_class.parse("u", '{"number":9,"state":"OPEN","isDraft":true,"title":"t","url":"u"}')
    expect(pr.state).to eq("DRAFT")
    expect(described_class.parse("u", '{"state":"OPEN","isDraft":false}').state).to eq("OPEN")
    expect(described_class.parse("u", '{"state":"MERGED","isDraft":false}')).to be_merged
    expect(described_class.parse("u", "garbage")).to be_nil
  end

  it "only accepts github pull request urls by hand" do
    expect(described_class.valid_url?("https://github.com/o/r/pull/12")).to be(true)
    expect(described_class.valid_url?("https://github.com/o/r/issues/12")).to be(false)
    expect(described_class.valid_url?("885")).to be(false)
  end

  it "asks gh until it has said when a PR was resolved, at most once per refresh window" do
    calls = []
    client = described_class.new(**cached, gh: "gh")
    allow(client).to receive(:fetch) do |url|
      calls << url
      ClaudeInbox::PullRequest.new(number: 885, url: url, state: "MERGED", resolved_at: now.to_i - 60)
    end
    client.status("https://github.com/jordanbyron/parks_genie/pull/885")
    client.status("https://github.com/jordanbyron/parks_genie/pull/885")
    expect(calls.size).to eq(1)
    expect(client.status("https://github.com/jordanbyron/parks_genie/pull/885")).to be_merged
  end

  it "asks gh once about a PR Claude Code's cache calls merged, since the cache never says when" do
    later = now
    client = described_class.new(**cached, clock: -> { later }, gh: "gh")
    url = "https://github.com/jordanbyron/parks_genie/pull/856"
    asked = 0
    allow(client).to receive(:fetch) do |u|
      asked += 1
      ClaudeInbox::PullRequest.new(number: 856, url: u, state: "MERGED", resolved_at: now.to_i - 60)
    end
    expect(client.status(url).resolved_at).to eq(now.to_i - 60)
    later = now + described_class::REFRESH_AFTER
    client.status(url)
    expect(asked).to eq(1)
  end

  # gh is a network round trip per PR, so enrich must never be the thing
  # that asks: the first frame waits on it.
  it "enriches without asking gh, and refresh is the slow half" do
    calls = []
    client = described_class.new(**cached, gh: "gh")
    allow(client).to receive(:fetch) do |url|
      calls << url
      n = url[/\d+\z/].to_i
      state = {856 => "MERGED", 866 => "CLOSED"}.fetch(n, "OPEN")
      ClaudeInbox::PullRequest.new(number: n, url: url, state: state, resolved_at: (now.to_i - 60 unless state == "OPEN"))
    end
    sessions = ClaudeInbox::JobState.enrich([
      session(id: "b03695b1"), # 856 and 866, both resolved in the cache
      session(id: "b0b18338")  # nothing scanned; linked by hand below
    ], jobs_dir: fixture_path("jobs"))
    a, b = client.enrich(sessions, {"b0b18338" => "https://github.com/o/r/pull/1"})
    expect(calls).to be_empty
    expect(a.prs.map(&:state)).to eq(%w[MERGED CLOSED])
    expect(b.prs.map(&:state)).to eq([nil])

    (fresh_a, fresh_b), moved = client.refresh([a, b])
    expect(moved).to be(true)
    expect(calls.map { |u| u[/\d+\z/] }).to eq(%w[856 866 1]) # the cache says 856 and 866 resolved, not when
    expect(fresh_b.prs.map(&:state)).to eq(%w[OPEN])
    _, moved = client.refresh([fresh_a, fresh_b])
    expect(moved).to be(false) # inside the refresh window: nothing moved
  end

  it "counts learning when a cached-merged PR was merged as a change" do
    client = described_class.new(**cached, gh: "gh")
    allow(client).to receive(:fetch) do |u|
      ClaudeInbox::PullRequest.new(number: 856, url: u, state: "MERGED", resolved_at: now.to_i - 60)
    end
    before = client.enrich([session(id: "x")], {"x" => "https://github.com/jordanbyron/parks_genie/pull/856"}).first
    expect(before.prs.map(&:state)).to eq(%w[MERGED])

    (after,), moved = client.refresh([before])
    expect(moved).to be(true)
    expect(after.prs.first.resolved_at).to eq(now.to_i - 60)
  end

  # The poller hands the list to the main thread before it asks gh, so the
  # answers must land on new sessions, not on the ones already published.
  it "leaves the sessions it refreshed as they were" do
    client = described_class.new(cache_path: nil, resolved_path: nil, gh: "gh", clock: -> { now })
    allow(client).to receive(:fetch) { |u| ClaudeInbox::PullRequest.new(number: 1, url: u, state: "OPEN") }
    before = client.enrich([session(id: "x")], {"x" => "https://github.com/o/r/pull/1"}).first
    expect(before.prs.map(&:state)).to eq([nil])

    (after,), moved = client.refresh([before])
    expect(moved).to be(true)
    expect(after.prs.map(&:state)).to eq(%w[OPEN])
    expect(before.prs.map(&:state)).to eq([nil])
  end

  it "remembers merged and closed PRs on disk so the next launch never asks" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "prs.json")
      url = "https://github.com/o/r/pull/7"
      first = described_class.new(cache_path: nil, resolved_path: path, gh: "gh", clock: -> { now })
      asked = 0
      allow(first).to receive(:fetch) do |u|
        asked += 1
        ClaudeInbox::PullRequest.new(number: 7, url: u, state: "MERGED", resolved_at: now.to_i - 60)
      end
      expect(first.status(url)).to be_merged
      expect(asked).to eq(1)
      expect(JSON.parse(File.read(path))[url]["state"]).to eq("MERGED")

      second = described_class.new(cache_path: nil, resolved_path: path, gh: "gh", clock: -> { now })
      allow(second).to receive(:fetch).and_raise("asked gh about a PR already known to be merged")
      pr = second.status(url)
      expect(pr).to be_merged
      expect(pr.resolved_at).to eq(now.to_i - 60)
    end
  end

  it "does not write anything a fetch left open" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "prs.json")
      client = described_class.new(cache_path: nil, resolved_path: path, gh: "gh", clock: -> { now })
      allow(client).to receive(:fetch) { |u| ClaudeInbox::PullRequest.new(number: 1, url: u, state: "OPEN") }
      client.status("https://github.com/o/r/pull/1")
      expect(File.exist?(path)).to be(false)
    end
  end
end
