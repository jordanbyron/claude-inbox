# frozen_string_literal: true

require "tmpdir"

PullRequests = ClaudeInbox::PullRequests
PullRequest = ClaudeInbox::PullRequest

RSpec.describe PullRequests do
  let(:now) { Time.at(1_789_600_000) }
  let(:prs) { PullRequests.new(cache_path: fixture_path("gh-pr-status-cache.json"), resolved_path: nil, gh: nil, clock: -> { now }) }

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
    sessions = ClaudeInbox::JobState.enrich([session(id: "b03695b1"), session(id: "b0b18338")], jobs_dir: fixture_path("jobs"))
    a, b = prs.enrich(sessions, {"b0b18338" => "https://github.com/o/r/pull/1"})
    expect(a.prs.map(&:number)).to eq([856, 866])
    expect(b.prs.map(&:number)).to eq([1])
  end

  it "parses gh output, calling an open draft DRAFT" do
    pr = PullRequests.parse("u", '{"number":9,"state":"OPEN","isDraft":true,"title":"t","url":"u"}')
    expect(pr.state).to eq("DRAFT")
    expect(PullRequests.parse("u", '{"state":"OPEN","isDraft":false}').state).to eq("OPEN")
    expect(PullRequests.parse("u", '{"state":"MERGED","isDraft":false}')).to be_merged
    expect(PullRequests.parse("u", "garbage")).to be_nil
  end

  it "only accepts github pull request urls by hand" do
    expect(PullRequests.valid_url?("https://github.com/o/r/pull/12")).to be(true)
    expect(PullRequests.valid_url?("https://github.com/o/r/issues/12")).to be(false)
    expect(PullRequests.valid_url?("885")).to be(false)
  end

  it "asks gh only for unresolved PRs and only once per refresh window" do
    calls = []
    client = PullRequests.new(cache_path: fixture_path("gh-pr-status-cache.json"), resolved_path: nil, gh: "gh", clock: -> { now })
    client.define_singleton_method(:fetch) do |url|
      calls << url
      PullRequest.new(number: 885, url: url, state: "MERGED")
    end
    client.status("https://github.com/jordanbyron/parks_genie/pull/856") # merged in cache: never asked
    client.status("https://github.com/jordanbyron/parks_genie/pull/885")
    client.status("https://github.com/jordanbyron/parks_genie/pull/885")
    expect(calls.size).to eq(1)
    expect(client.status("https://github.com/jordanbyron/parks_genie/pull/885")).to be_merged
  end

  # gh is a network round trip per PR, so enrich must never be the thing
  # that asks: the first frame waits on it.
  it "enriches without asking gh, and refresh is the slow half" do
    calls = []
    client = PullRequests.new(cache_path: fixture_path("gh-pr-status-cache.json"), resolved_path: nil, gh: "gh", clock: -> { now })
    client.define_singleton_method(:fetch) do |url|
      calls << url
      PullRequest.new(number: url[/\d+\z/].to_i, url: url, state: "OPEN")
    end
    sessions = ClaudeInbox::JobState.enrich([
      session(id: "b03695b1"), # 856 and 866, both resolved in the cache
      session(id: "b0b18338")  # nothing scanned; linked by hand below
    ], jobs_dir: fixture_path("jobs"))
    a, b = client.enrich(sessions, {"b0b18338" => "https://github.com/o/r/pull/1"})
    expect(calls).to be_empty
    expect(a.prs.map(&:state)).to eq(%w[MERGED CLOSED])
    expect(b.prs.map(&:state)).to eq([nil])

    (_, fresh_b), moved = client.refresh([a, b])
    expect(moved).to be(true)
    expect(calls.map { |u| u[/\d+\z/] }).to eq(%w[1]) # resolved PRs are never asked about
    expect(fresh_b.prs.map(&:state)).to eq(%w[OPEN])
    _, moved = client.refresh([a, fresh_b])
    expect(moved).to be(false) # inside the refresh window: nothing moved
  end

  # The poller hands the list to the main thread before it asks gh, so the
  # answers must land on new sessions, not on the ones already published.
  it "leaves the sessions it refreshed as they were" do
    client = PullRequests.new(cache_path: nil, resolved_path: nil, gh: "gh", clock: -> { now })
    client.define_singleton_method(:fetch) { |u| PullRequest.new(number: 1, url: u, state: "OPEN") }
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
      first = PullRequests.new(cache_path: nil, resolved_path: path, gh: "gh", clock: -> { now })
      asked = 0
      first.define_singleton_method(:fetch) do |u|
        asked += 1
        PullRequest.new(number: 7, url: u, state: "MERGED", title: "seven")
      end
      expect(first.status(url)).to be_merged
      expect(asked).to eq(1)
      expect(JSON.parse(File.read(path))[url]["state"]).to eq("MERGED")

      second = PullRequests.new(cache_path: nil, resolved_path: path, gh: "gh", clock: -> { now })
      second.define_singleton_method(:fetch) { |_| raise "asked gh about a PR already known to be merged" }
      pr = second.status(url)
      expect(pr).to be_merged
      expect(pr.title).to eq("seven")
    end
  end

  it "does not write anything a fetch left open" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "prs.json")
      client = PullRequests.new(cache_path: nil, resolved_path: path, gh: "gh", clock: -> { now })
      client.define_singleton_method(:fetch) { |u| PullRequest.new(number: 1, url: u, state: "OPEN") }
      client.status("https://github.com/o/r/pull/1")
      expect(File.exist?(path)).to be(false)
    end
  end
end
