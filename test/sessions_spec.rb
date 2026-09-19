# frozen_string_literal: true

require_relative "test_helper"

describe ClaudeInbox::Sessions do
  let(:client) { ClaudeInbox::FixtureClient.new(fixture_path("agents.json")) }
  let(:pull_requests) { ClaudeInbox::PullRequests.new(cache_path: fixture_path("gh-pr-status-cache.json"), resolved_path: nil, gh: nil) }

  def load(overrides = {})
    ClaudeInbox::Sessions.load(client: client, jobs_dir: fixture_path("jobs"), pull_requests: pull_requests, overrides: overrides)
  end

  # The PR numbers can only come out if JobState was past before
  # PullRequests: that is the order the loader exists to hold.
  it "hands back the daemon's list with each job file and its pull requests attached" do
    sessions = load
    _(sessions.map(&:key)).must_equal client.list.map(&:key)
    linked = sessions.find { |s| s.id == "b03695b1" }
    _(linked.job_state).wont_be_nil
    _(linked.prs.map(&:number)).must_equal [856, 866]
    _(linked.prs.map(&:state)).must_equal %w[MERGED CLOSED]
  end

  it "leaves an interactive session with no job file and no pull requests" do
    term = load.find(&:interactive?)
    _(term.job_state).must_be_nil
    _(term.prs).must_equal []
  end

  it "lets an override stand in for the scanned links" do
    s = load({"b03695b1" => "https://github.com/o/r/pull/9"}).find { |x| x.id == "b03695b1" }
    _(s.prs.map(&:number)).must_equal [9]
  end
end
