# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

PullRequests = ClaudeInbox::PullRequests
PullRequest = ClaudeInbox::PullRequest

describe PullRequests do
  let(:now) { Time.at(1_789_600_000) }
  let(:prs) { PullRequests.new(cache_path: fixture_path("gh-pr-status-cache.json"), resolved_path: nil, gh: nil, clock: -> { now }) }

  it "seeds state from Claude Code's own cache" do
    pr = prs.status("https://github.com/jordanbyron/parks_genie/pull/885")
    _(pr.number).must_equal 885
    _(pr.state).must_equal "DRAFT"
    _(pr.short).must_equal "#885"
    _(pr).wont_be :resolved?
  end

  it "knows the number but not the state of a PR nobody has cached" do
    pr = prs.status("https://github.com/o/r/pull/42")
    _(pr.number).must_equal 42
    _(pr).wont_be :known?
  end

  it "enriches sessions, letting an override replace the scanned list" do
    sessions = ClaudeInbox::JobState.enrich([session(id: "b03695b1"), session(id: "b0b18338")], jobs_dir: fixture_path("jobs"))
    a, b = prs.enrich(sessions, {"b0b18338" => "https://github.com/o/r/pull/1"})
    _(a.prs.map(&:number)).must_equal [856, 866]
    _(b.prs.map(&:number)).must_equal [1]
  end

  it "parses gh output, calling an open draft DRAFT" do
    pr = PullRequests.parse("u", '{"number":9,"state":"OPEN","isDraft":true,"title":"t","url":"u"}')
    _(pr.state).must_equal "DRAFT"
    _(PullRequests.parse("u", '{"state":"OPEN","isDraft":false}').state).must_equal "OPEN"
    _(PullRequests.parse("u", '{"state":"MERGED","isDraft":false}')).must_be :merged?
    _(PullRequests.parse("u", "garbage")).must_be_nil
  end

  it "only accepts github pull request urls by hand" do
    _(PullRequests.valid_url?("https://github.com/o/r/pull/12")).must_equal true
    _(PullRequests.valid_url?("https://github.com/o/r/issues/12")).must_equal false
    _(PullRequests.valid_url?("885")).must_equal false
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
    _(calls.size).must_equal 1
    _(client.status("https://github.com/jordanbyron/parks_genie/pull/885")).must_be :merged?
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
    _(calls).must_be_empty
    _(a.prs.map(&:state)).must_equal %w[MERGED CLOSED]
    _(b.prs.map(&:state)).must_equal [nil]

    (_, fresh_b), moved = client.refresh([a, b])
    _(moved).must_equal true
    _(calls.map { |u| u[/\d+\z/] }).must_equal %w[1] # resolved PRs are never asked about
    _(fresh_b.prs.map(&:state)).must_equal %w[OPEN]
    _, moved = client.refresh([a, fresh_b])
    _(moved).must_equal false # inside the refresh window: nothing moved
  end

  # The poller hands the list to the main thread before it asks gh, so the
  # answers must land on new sessions, not on the ones already published.
  it "leaves the sessions it refreshed as they were" do
    client = PullRequests.new(cache_path: nil, resolved_path: nil, gh: "gh", clock: -> { now })
    client.define_singleton_method(:fetch) { |u| PullRequest.new(number: 1, url: u, state: "OPEN") }
    before = client.enrich([session(id: "x")], {"x" => "https://github.com/o/r/pull/1"}).first
    _(before.prs.map(&:state)).must_equal [nil]

    (after,), moved = client.refresh([before])
    _(moved).must_equal true
    _(after.prs.map(&:state)).must_equal %w[OPEN]
    _(before.prs.map(&:state)).must_equal [nil]
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
      _(first.status(url)).must_be :merged?
      _(asked).must_equal 1
      _(JSON.parse(File.read(path))[url]["state"]).must_equal "MERGED"

      second = PullRequests.new(cache_path: nil, resolved_path: path, gh: "gh", clock: -> { now })
      second.define_singleton_method(:fetch) { |_| flunk "asked gh about a PR already known to be merged" }
      pr = second.status(url)
      _(pr).must_be :merged?
      _(pr.title).must_equal "seven"
    end
  end

  it "does not write anything a fetch left open" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "prs.json")
      client = PullRequests.new(cache_path: nil, resolved_path: path, gh: "gh", clock: -> { now })
      client.define_singleton_method(:fetch) { |u| PullRequest.new(number: 1, url: u, state: "OPEN") }
      client.status("https://github.com/o/r/pull/1")
      _(File.exist?(path)).must_equal false
    end
  end
end
