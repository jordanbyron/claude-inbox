# frozen_string_literal: true

RSpec.describe ClaudeInbox::Sessions do
  subject(:sessions) { described_class.load(client: client, pull_requests: pull_requests, overrides: overrides) }

  let(:client) { ClaudeInbox::Claude::FixtureClient.new(fixture_path("agents.json")) }
  let(:pull_requests) do
    ClaudeInbox::PullRequests.new(cache_path: fixture_path("gh-pr-status-cache.json"), resolved_path: nil, gh: nil)
  end
  let(:overrides) { {} }

  # The PR numbers can only come out of the links the adapter scanned.
  it "hands back the daemon's list with each session's pull requests attached" do
    expect(sessions.map(&:key)).to eq(client.list.map(&:key))
    linked = sessions.find { |s| s.id == "b03695b1" }
    expect(linked.prs.map(&:number)).to eq([856, 866])
    expect(linked.prs.map(&:state)).to eq(%w[MERGED CLOSED])
  end

  it "fills in each session's color from its job file" do
    by_id = sessions.to_h { |s| [s.id, s.color] }
    expect(by_id["b0b18338"]).to eq("orange")
    expect(by_id["b03695b1"]).to be_nil
  end

  it "leaves an interactive session with no job file and no pull requests" do
    term = sessions.find(&:interactive?)
    expect(term.pr_urls).to eq([])
    expect(term.prs).to eq([])
  end

  context "when an override names a session" do
    let(:overrides) { {"b03695b1" => "https://github.com/o/r/pull/9"} }

    it "lets an override stand in for the scanned links" do
      s = sessions.find { |x| x.id == "b03695b1" }
      expect(s.prs.map(&:number)).to eq([9])
    end
  end
end
