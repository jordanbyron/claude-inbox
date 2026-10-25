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
    expect(pr.title).to eq("feat(sensors): edge probe")
    expect(pr.short).to eq("PR #885")
    expect(pr).not_to be_resolved
    expect(pr.health).to be_nil
  end

  it "reads what is wrong with an open PR, and nothing of a resolved one" do
    view = ->(**fields) {
      described_class.parse("u", JSON.generate({"number" => 9, "state" => "OPEN", "isDraft" => false,
                                                "statusCheckRollup" => [{"__typename" => "CheckRun", "status" => "COMPLETED", "conclusion" => "SUCCESS"}],
                                                "reviewDecision" => "", "mergeable" => "MERGEABLE"}.merge(fields)))
    }
    expect(view.call.health).to eq("CLEAN")
    failing = [{"__typename" => "StatusContext", "state" => "FAILURE"}, {"__typename" => "CheckRun", "conclusion" => "SUCCESS"}]
    expect(view.call("statusCheckRollup" => failing).health).to eq("FAILING")
    expect(view.call("statusCheckRollup" => [{"__typename" => "CheckRun", "status" => "IN_PROGRESS", "conclusion" => nil}]).health).to eq("CLEAN")
    expect(view.call("reviewDecision" => "CHANGES_REQUESTED").health).to eq("CHANGES_REQUESTED")
    expect(view.call("reviewDecision" => "CHANGES_REQUESTED", "statusCheckRollup" => failing).health).to eq("FAILING")
    expect(view.call("mergeable" => "CONFLICTING").health).to eq("CONFLICTING")
    expect(view.call("mergeable" => "UNKNOWN").health).to eq("CLEAN")
    expect(view.call("isDraft" => true, "mergeable" => "CONFLICTING").health).to eq("CONFLICTING")
    expect(view.call("state" => "MERGED", "closedAt" => "2026-09-28T14:00:00Z", "mergeable" => "CONFLICTING").health).to be_nil
    expect(described_class.parse("u", '{"state":"OPEN","isDraft":false}').health).to eq("CLEAN")
  end

  it "judges a check by its latest run, not the ones a newer run superseded" do
    run = ->(conclusion, started) {
      {"__typename" => "CheckRun", "workflowName" => "PR Checks", "name" => "PR Checks",
       "conclusion" => conclusion, "startedAt" => started}
    }
    health = ->(*checks) {
      described_class.parse("u", JSON.generate("state" => "OPEN", "statusCheckRollup" => checks)).health
    }
    expect(health.call(run.call("CANCELLED", "2026-10-16T13:16:02Z"), run.call("SUCCESS", "2026-10-16T13:40:00Z"))).to eq("CLEAN")
    expect(health.call(run.call("SUCCESS", "2026-10-16T13:16:02Z"), run.call("FAILURE", "2026-10-16T13:40:00Z"))).to eq("FAILING")
    other = run.call("FAILURE", "2026-10-16T13:00:00Z").merge("workflowName" => "Lint")
    expect(health.call(other, run.call("SUCCESS", "2026-10-16T13:40:00Z"))).to eq("FAILING")
  end

  it "names its repo from a github pull url, and qualifies its number with it" do
    pr = ClaudeInbox::PullRequest.new(number: 1020, url: "https://github.com/jordanbyron/parks_genie/pull/1020")
    expect(pr.repo).to eq("jordanbyron/parks_genie")
    expect(pr.qualified).to eq("jordanbyron/parks_genie#1020")
    elsewhere = ClaudeInbox::PullRequest.new(number: 4, url: "https://gitlab.com/o/r/-/merge_requests/4")
    expect(elsewhere.repo).to be_nil
    expect(elsewhere.qualified).to eq("MR !4")
  end

  it "names a pull request as Claude Code does, and a link it can't number by its address" do
    expect(ClaudeInbox::PullRequest.new(number: 885, url: "https://github.com/o/r/pull/885").short).to eq("PR #885")
    expect(ClaudeInbox::PullRequest.new(url: "https://gitlab.com/c/uk43/-/merge_requests/3413").short).to eq("MR !3413")
    expect(ClaudeInbox::PullRequest.new(url: "https://bitbucket.org/o/r/pull-requests/2").short).to eq("bitbucket.org/o/r/pull-requests/2")
  end

  it "wants you back for failing checks and requested changes, not for a conflict" do
    expect(ClaudeInbox::PullRequest.new(state: "OPEN", health: "FAILING")).to be_needs_you
    expect(ClaudeInbox::PullRequest.new(state: "OPEN", health: "CHANGES_REQUESTED")).to be_needs_you
    expect(ClaudeInbox::PullRequest.new(state: "OPEN", health: "CONFLICTING")).not_to be_needs_you
    expect(ClaudeInbox::PullRequest.new(state: "OPEN", health: "CLEAN")).not_to be_needs_you
    expect(ClaudeInbox::PullRequest.new(state: "OPEN")).not_to be_needs_you
  end

  it "asks gh for the state and the health in the one call" do
    client = described_class.new(cache_path: nil, resolved_path: nil, gh: "gh", clock: -> { now })
    out = '{"number":1,"state":"OPEN","isDraft":false,"statusCheckRollup":[{"conclusion":"FAILURE"}]}'
    ok = instance_double(Process::Status, success?: true)
    expect(ClaudeInbox::Subprocess).to receive(:capture)
      .with("gh", "pr", "view", "https://github.com/o/r/pull/1", "--json",
        "number,state,isDraft,url,closedAt,statusCheckRollup,reviewDecision,mergeable,title")
      .once.and_return(ClaudeInbox::Subprocess::Result.new(out, "", ok))
    pr = client.status("https://github.com/o/r/pull/1")
    expect(pr.state).to eq("OPEN")
    expect(pr.health).to eq("FAILING")
  end

  it "counts a change of health as a change worth publishing" do
    later = now
    health = "CLEAN"
    client = described_class.new(cache_path: nil, resolved_path: nil, gh: "gh", clock: -> { later })
    allow(client).to receive(:fetch) { |u| ClaudeInbox::PullRequest.new(number: 1, url: u, state: "OPEN", health: health) }
    before = client.enrich([session(id: "x")], {"x" => "https://github.com/o/r/pull/1"}).first
    (open,), _ = client.refresh([before])
    expect(open.prs.first.health).to eq("CLEAN")

    later = now + described_class::REFRESH_AFTER
    health = "FAILING"
    (failing,), moved = client.refresh([open])
    expect(moved).to be(true)
    expect(failing.prs.first.health).to eq("FAILING")
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

  it "adds the rest of a stack the session opened to the daemon's one link" do
    Dir.mktmpdir do |dir|
      transcript = File.join(dir, "t.jsonl")
      stdout = (1..3).map { |n| "✓ Created PR ##{n} (https://github.com/o/r/pull/#{n}) for b#{n}" }.join("\n")
      File.write(transcript, JSON.generate("toolUseResult" => {"stdout" => stdout}) + "\n")
      FileUtils.mkdir_p(File.join(dir, "aaa11111"))
      File.write(File.join(dir, "aaa11111", "state.json"), JSON.generate("linkScanPath" => transcript,
        "children" => [{"kind" => "pr", "href" => "https://github.com/o/r/pull/1"}]))
      sessions = ClaudeInbox::JobState.enrich([session(id: "aaa11111")], jobs_dir: dir)
      expect(prs.enrich(sessions, {}).first.prs.map(&:number)).to eq([1, 2, 3])
    end
  end

  it "reads when gh says a PR was merged or closed" do
    json = '{"number":9,"state":"MERGED","isDraft":false,"closedAt":"2026-09-28T14:00:00Z"}'
    expect(described_class.parse("u", json).resolved_at).to eq(Time.utc(2026, 9, 28, 14).to_i)
    expect(described_class.parse("u", '{"state":"OPEN","isDraft":false,"closedAt":null}').resolved_at).to be_nil
  end

  it "parses gh output, calling an open draft DRAFT" do
    pr = described_class.parse("u", '{"number":9,"state":"OPEN","isDraft":true,"title":"t","url":"u"}')
    expect(pr.state).to eq("DRAFT")
    expect(pr.title).to eq("t")
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
        ClaudeInbox::PullRequest.new(number: 7, url: u, state: "MERGED", resolved_at: now.to_i - 60, title: "Ship it")
      end
      expect(first.status(url)).to be_merged
      expect(asked).to eq(1)
      expect(JSON.parse(File.read(path))[url]["state"]).to eq("MERGED")

      second = described_class.new(cache_path: nil, resolved_path: path, gh: "gh", clock: -> { now })
      allow(second).to receive(:fetch).and_raise("asked gh about a PR already known to be merged")
      pr = second.status(url)
      expect(pr).to be_merged
      expect(pr.resolved_at).to eq(now.to_i - 60)
      expect(pr.title).to eq("Ship it")
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
