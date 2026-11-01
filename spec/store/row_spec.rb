# frozen_string_literal: true

RSpec.describe ClaudeInbox::Store::Row do
  let(:now) { Time.at(1_789_600_000) }

  it "shows the alias over the session's name, and searches label or cwd" do
    plain = described_class.new(session(id: "a", name: "Thing", cwd: "/srv/Other"), nil)
    expect(plain.label).to eq("Thing")
    expect(plain.alias_name).to be_nil
    expect(plain.matches?("thing")).to be(true)
    expect(plain.matches?("other")).to be(true)
    expect(plain.matches?("zzz")).to be(false)

    aliased = described_class.new(session(id: "a", name: "Thing"), ClaudeInbox::Store::Entry.new("alias" => "flaky"))
    expect(aliased.label).to eq("flaky")
    expect(aliased.matches?("flaky")).to be(true)
    expect(aliased.matches?("thing")).to be(false)
  end

  describe "searching a session you cannot name" do
    it "searches the prompt the session was started with" do
      r = described_class.new(session(id: "a", name: "SEAR-1594", cwd: "/srv/app",
        intent: "Restore the OpenSearch indexes in Sagemaker"), nil)
      expect(r.matches?("opensearch")).to be(true)
      expect(r.matches?("sagemaker")).to be(true)
      expect(r.matches?("kubernetes")).to be(false)
    end

    it "searches the line the session is showing about itself" do
      r = described_class.new(session(id: "a", name: "SEAR-1594", state: "working",
        line: "Reading the synonym-mode application"), nil)
      expect(r.matches?("synonym")).to be(true)
    end

    it "searches each pull request by number, repo, url or title" do
      prs = [
        ClaudeInbox::PullRequest.new(number: 885, url: "https://github.com/acme/app/pull/885", title: "Fix the reindex"),
        ClaudeInbox::PullRequest.new(number: 912, url: "https://github.com/acme/lib/pull/912")
      ]
      r = described_class.new(session(id: "a", name: "SEAR-1594", cwd: "/srv/app", prs:), nil)
      expect(r.matches?("#885")).to be(true)
      expect(r.matches?("#912")).to be(true)
      expect(r.matches?("acme/lib#912")).to be(true)
      expect(r.matches?("https://github.com/acme/app/pull/885")).to be(true)
      expect(r.matches?("reindex")).to be(true)
      expect(r.matches?("#88")).to be(true)
      expect(r.matches?("#1885")).to be(false)
      expect(r.matches?("#913")).to be(false)
    end

    it "leaves an interactive session searchable by name and cwd alone" do
      r = described_class.new(session(id: nil, session_id: "u1", kind: "interactive", name: "shell",
        cwd: "/srv/app"), nil)
      expect(r.matches?("shell")).to be(true)
      expect(r.matches?("app")).to be(true)
      expect(r.matches?("opensearch")).to be(false)
    end
  end

  it "answers nil for every reader when no poll has recorded the session yet" do
    r = described_class.new(session(id: "a"), nil)
    expect(r.entry).to be_nil
    expect(r.wake_at).to be_nil
    expect(r.state_since).to be_nil
    expect(r.pinned_at).to be_nil
    expect(r.pinned?).to be_nil
    expect(r.parked?).to be_nil
    expect(r.reap_failed_at).to be_nil
    expect(r.section(now)).to eq(:active)
  end

  it "is selectable only with a key" do
    expect(described_class.new(session(id: "a"), nil)).to be_selectable
    expect(described_class.new(session(id: nil, session_id: nil, kind: "interactive"), nil)).not_to be_selectable
  end

  it "reads the entry through its accessors" do
    entry = ClaudeInbox::Store::Entry.new(
      "wake_at" => ClaudeInbox::Store::UNTIL_WOKEN,
      "state_since" => 5,
      "pinned" => true,
      "pinned_at" => 6,
      "reap_failed_at" => 7
    )
    r = described_class.new(session(id: "a"), entry)
    expect(r.wake_at).to eq(ClaudeInbox::Store::UNTIL_WOKEN)
    expect(r.parked?).to be(true)
    expect(r.state_since).to eq(5)
    expect(r.pinned?).to be(true)
    expect(r.pinned_at).to eq(6)
    expect(r.reap_failed_at).to eq(7)
  end

  describe "unread rule" do
    let(:finished) { {"last_state" => "done", "state_since" => now.to_i - 60} }

    it "marks a finished or blocked session nobody has attached to since it got there" do
      expect(described_class.new(session(id: "a", state: "done"), ClaudeInbox::Store::Entry.new(finished))).to be_unread
      expect(described_class.new(session(id: "a", state: "idle"), ClaudeInbox::Store::Entry.new(finished))).to be_unread
      expect(described_class.new(session(id: "a", state: "blocked"), ClaudeInbox::Store::Entry.new(finished))).to be_unread
      expect(described_class.new(session(id: "a", state: "done"), nil)).to be_unread
    end

    it "reads as seen once attached to after the state changed, and unread again when it changes after" do
      seen = ClaudeInbox::Store::Entry.new(finished.merge("last_visited_at" => now.to_i - 30))
      expect(described_class.new(session(id: "a", state: "done"), seen)).not_to be_unread
      expect(described_class.new(session(id: "a", state: "done"), seen)).to be_read
      expect(described_class.new(session(id: "a", state: "blocked"), seen)).to be_read
      earlier = ClaudeInbox::Store::Entry.new(finished.merge("last_visited_at" => now.to_i - 90))
      expect(described_class.new(session(id: "a", state: "done"), earlier)).to be_unread
      expect(described_class.new(session(id: "a", state: "done"), earlier)).not_to be_read
    end

    it "leaves a working session, and one there is no way to attach to, alone" do
      expect(described_class.new(session(id: "a", state: "working"), nil)).not_to be_unread
      expect(described_class.new(session(id: "a", state: "working"), nil)).not_to be_read
      shell = session(id: nil, kind: "interactive", state: nil, status: "idle", session_id: "u9", actions: [])
      expect(described_class.new(shell, ClaudeInbox::Store::Entry.new(finished))).not_to be_unread
      expect(described_class.new(shell, ClaudeInbox::Store::Entry.new(finished))).not_to be_read
      codex = session(id: "t", state: "done", harness: :codex, actions: [])
      expect(described_class.new(codex, ClaudeInbox::Store::Entry.new(finished))).not_to be_unread
      expect(described_class.new(codex, ClaudeInbox::Store::Entry.new(finished))).not_to be_read
    end
  end

  describe "pull request rule" do
    let(:entry) { ClaudeInbox::Store::Entry.new("last_state" => "done", "state_since" => now.to_i - 60) }
    let(:open) { ->(health) { [ClaudeInbox::PullRequest.new(number: 7, state: "OPEN", health: health)] } }

    it "puts a stopped session in Needs You when its PR has failing checks or changes requested" do
      failing = described_class.new(session(id: "a", state: "done", prs: open.call("FAILING")), entry)
      expect(failing).to be_pr_needs_you
      expect(failing.section(now)).to eq(:needs_you)
      changes = described_class.new(session(id: "a", state: "idle", prs: open.call("CHANGES_REQUESTED")), entry)
      expect(changes.section(now)).to eq(:needs_you)
    end

    it "leaves a conflict, a clean PR and one gh has not described in Active" do
      ["CONFLICTING", "CLEAN", nil].each do |health|
        r = described_class.new(session(id: "a", state: "done", prs: open.call(health)), entry)
        expect(r).not_to be_pr_needs_you
        expect(r.section(now)).to eq(:active)
      end
    end

    it "waits while the agent is still working" do
      r = described_class.new(session(id: "a", state: "working", prs: open.call("FAILING")), entry)
      expect(r).not_to be_pr_needs_you
      expect(r.section(now)).to eq(:active)
    end

    it "moves to Active once attached to, like a blocked session, and settles on x" do
      seen = ClaudeInbox::Store::Entry.new("last_state" => "done", "state_since" => now.to_i - 60, "acknowledged_at" => now.to_i - 30)
      r = described_class.new(session(id: "a", state: "done", prs: open.call("FAILING")), seen)
      expect(r).to be_pr_needs_you
      expect(r.section(now)).to eq(:active)
      settled = ClaudeInbox::Store::Entry.new("last_state" => "done", "state_since" => now.to_i - 60, "settled_at" => now.to_i - 30)
      expect(described_class.new(session(id: "a", state: "done", prs: open.call("FAILING")), settled).section(now)).to eq(:settled)
    end

    it "goes by the PR the badge shows, the troubled one, and never by one with no entry yet" do
      prs = [ClaudeInbox::PullRequest.new(number: 1, state: "OPEN", health: "CLEAN"), *open.call("FAILING")]
      expect(described_class.new(session(id: "a", state: "done", prs: prs), entry).section(now)).to eq(:needs_you)
      expect(described_class.new(session(id: "a", state: "done", prs: open.call("FAILING")), nil).section(now)).to eq(:needs_you)
    end
  end

  describe "working fold" do
    let(:entry) { ClaudeInbox::Store::Entry.new("last_state" => "working", "state_since" => now.to_i - 60) }

    it "folds a session still at work only when asked, and lets it out when it stops" do
      r = described_class.new(session(id: "a", state: "working"), entry)
      expect(r.section(now)).to eq(:active)
      expect(r.section(now, fold_working: true)).to eq(:working)
      done = described_class.new(session(id: "a", state: "done"), entry)
      expect(done.section(now, fold_working: true)).to eq(:active)
      quiet = described_class.new(session(id: "a", state: "working", in_flight: "1 shell", busy: false), entry)
      expect(quiet.section(now, fold_working: true)).to eq(:active)
    end

    it "keeps a pinned, snoozed or terminal session out of the fold" do
      pinned = ClaudeInbox::Store::Entry.new("pinned" => true, "pinned_at" => now.to_i)
      expect(described_class.new(session(id: "a", state: "working"), pinned).section(now, fold_working: true)).to eq(:pinned)
      snoozed = ClaudeInbox::Store::Entry.new("wake_at" => now.to_i + 900)
      expect(described_class.new(session(id: "a", state: "working"), snoozed).section(now, fold_working: true)).to eq(:snoozed)
      term = described_class.new(session(id: nil, kind: "interactive", state: nil, status: "busy", session_id: "uuid"), nil)
      expect(term.section(now, fold_working: true)).to eq(:active)
    end
  end

  describe "reap rule" do
    let(:quiet) { {"last_state" => "done", "state_since" => now.to_i - ClaudeInbox::Store::REAP_AFTER - 1} }
    let(:recent) { {"last_state" => "done", "state_since" => now.to_i - ClaudeInbox::Store::REAP_AFTER + 60} }

    it "reaps a finished session quiet for longer than REAP_AFTER" do
      expect(described_class.new(session(id: "a", state: "done"), ClaudeInbox::Store::Entry.new(quiet))).to be_reapable(now.to_i)
    end

    it "leaves one that has been quiet for less" do
      expect(described_class.new(session(id: "a", state: "done"), ClaudeInbox::Store::Entry.new(recent))).not_to be_reapable(now.to_i)
    end

    it "reaps on idle time alone, where settling waits on the pull request" do
      s = session(id: "a", state: "done", prs: [ClaudeInbox::PullRequest.new(state: "DRAFT")])
      expect(described_class.new(s, ClaudeInbox::Store::Entry.new(quiet)).settled?).to be(false)
      expect(described_class.new(s, ClaudeInbox::Store::Entry.new(quiet))).to be_reapable(now.to_i)
    end

    it "reaps a long-dead failure, which never settles" do
      s = session(id: "a", state: "error")
      expect(described_class.new(s, ClaudeInbox::Store::Entry.new(quiet)).settled?).to be(false)
      expect(described_class.new(s, ClaudeInbox::Store::Entry.new(quiet))).to be_reapable(now.to_i)
    end

    it "never reaps a session its harness does not offer up, even one it can delete" do
      s = session(id: "a", state: "done", actions: %i[attach stop delete])
      expect(described_class.new(s, ClaudeInbox::Store::Entry.new(quiet))).not_to be_reapable(now.to_i)
    end

    it "never reaps a Codex thread, which nothing stops deleting with unpushed work" do
      s = session(id: "a", state: "done", harness: :codex, actions: ClaudeInbox::Codex::ThreadsClient::ACTIONS)
      expect(described_class.new(s, ClaudeInbox::Store::Entry.new(quiet))).not_to be_reapable(now.to_i)
    end

    it "never reaps a working session" do
      expect(described_class.new(session(id: "a", state: "working"), ClaudeInbox::Store::Entry.new(quiet))).not_to be_reapable(now.to_i)
    end

    it "never reaps one that still has a process" do
      expect(described_class.new(session(id: "a", state: "done", pid: 4321), ClaudeInbox::Store::Entry.new(quiet))).not_to be_reapable(now.to_i)
    end

    it "never reaps a pin or a snooze, however long it has been parked" do
      expect(described_class.new(session(id: "a", state: "done"), ClaudeInbox::Store::Entry.new(quiet.merge("pinned" => true)))).not_to be_reapable(now.to_i)
      expect(described_class.new(session(id: "a", state: "done"), ClaudeInbox::Store::Entry.new(quiet.merge("wake_at" => ClaudeInbox::Store::UNTIL_WOKEN)))).not_to be_reapable(now.to_i)
    end

    it "reaps once an elapsed snooze has woken it" do
      woken = quiet.merge("wake_at" => now.to_i - 60)
      expect(described_class.new(session(id: "a", state: "done"), ClaudeInbox::Store::Entry.new(woken))).to be_reapable(now.to_i)
    end

    it "never reaps a terminal, which no harness offers up" do
      s = session(id: nil, kind: "interactive", state: nil, status: "idle", session_id: "u9", actions: [])
      expect(described_class.new(s, ClaudeInbox::Store::Entry.new(quiet))).not_to be_reapable(now.to_i)
    end

    it "never reaps a session it has no entry for" do
      expect(described_class.new(session(id: "a", state: "done"), nil)).not_to be_reapable(now.to_i)
    end
  end
end
