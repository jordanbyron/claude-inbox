# frozen_string_literal: true

RSpec.describe ClaudeInbox::Sessions do
  let(:client) { ClaudeInbox::FixtureClient.new(fixture_path("agents.json")) }
  let(:pull_requests) { ClaudeInbox::PullRequests.new(cache_path: fixture_path("gh-pr-status-cache.json"), resolved_path: nil, gh: nil) }

  def load(overrides = {})
    ClaudeInbox::Sessions.load(client: client, pull_requests: pull_requests, overrides: overrides)
  end

  # The PR numbers can only come out if JobState was past before
  # PullRequests: that is the order the loader exists to hold.
  it "hands back the daemon's list with each job file and its pull requests attached" do
    sessions = load
    expect(sessions.map(&:key)).to eq(client.list.map(&:key))
    linked = sessions.find { |s| s.id == "b03695b1" }
    expect(linked.job_state).not_to be_nil
    expect(linked.prs.map(&:number)).to eq([856, 866])
    expect(linked.prs.map(&:state)).to eq(%w[MERGED CLOSED])
  end

  it "fills in each session's color from its job file" do
    by_id = load.to_h { |s| [s.id, s.color] }
    expect(by_id["b0b18338"]).to eq("orange")
    expect(by_id["b03695b1"]).to be_nil
  end

  it "leaves an interactive session with no job file and no pull requests" do
    term = load.find(&:interactive?)
    expect(term.job_state).to be_nil
    expect(term.prs).to eq([])
  end

  it "lets an override stand in for the scanned links" do
    s = load({"b03695b1" => "https://github.com/o/r/pull/9"}).find { |x| x.id == "b03695b1" }
    expect(s.prs.map(&:number)).to eq([9])
  end
end
