# frozen_string_literal: true

require_relative "test_helper"

PullRequests = ClaudeInbox::PullRequests
PullRequest = ClaudeInbox::PullRequest

describe PullRequests do
  let(:now) { Time.at(1_789_600_000) }
  let(:prs) { PullRequests.new(jobs_dir: fixture_path("jobs"), cache_path: fixture_path("gh-pr-status-cache.json"), gh: nil, clock: -> { now }) }

  it "reads the PRs the daemon scanned out of a job, skipping issues" do
    _(prs.linked("b03695b1").map { |u| u[/\d+\z/] }).must_equal %w[856 866]
    _(prs.linked("nope")).must_be_empty
    _(prs.linked(nil)).must_be_empty
  end

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
    a = session(id: "b03695b1")
    b = session(id: "b0b18338")
    prs.enrich([a, b], {"b0b18338" => "https://github.com/o/r/pull/1"})
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
    client = PullRequests.new(jobs_dir: fixture_path("jobs"), cache_path: fixture_path("gh-pr-status-cache.json"), gh: "gh", clock: -> { now })
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
end
