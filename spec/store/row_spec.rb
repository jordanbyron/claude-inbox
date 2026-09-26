# frozen_string_literal: true

RSpec.describe ClaudeInbox::Store::Row, :store, :store_row do
  let(:now) { Time.at(1_789_600_000) }

  it "shows the alias over the session's name, and searches label or cwd" do
    plain = row(session(id: "a", name: "Thing", cwd: "/srv/Other"), nil)
    expect(plain.label).to eq("Thing")
    expect(plain.alias_name).to be_nil
    expect(plain.matches?("thing")).to be(true)
    expect(plain.matches?("other")).to be(true)
    expect(plain.matches?("zzz")).to be(false)

    aliased = row(session(id: "a", name: "Thing"), {"alias" => "flaky"})
    expect(aliased.label).to eq("flaky")
    expect(aliased.matches?("flaky")).to be(true)
    expect(aliased.matches?("thing")).to be(false)
  end

  describe "searching a session you cannot name" do
    it "searches the prompt the session was started with" do
      r = row(session(id: "a", name: "SEAR-1594", cwd: "/srv/app",
        job_state: ClaudeInbox::JobState.new("intent" => "Restore the OpenSearch indexes in Sagemaker")), nil)
      expect(r.matches?("opensearch")).to be(true)
      expect(r.matches?("sagemaker")).to be(true)
      expect(r.matches?("kubernetes")).to be(false)
    end

    it "searches the line the session is showing about itself" do
      r = row(session(id: "a", name: "SEAR-1594", state: "working",
        job_state: ClaudeInbox::JobState.new("detail" => "Reading the synonym-mode application")), nil)
      expect(r.matches?("synonym")).to be(true)
    end

    it "leaves an interactive session searchable by name and cwd alone" do
      r = row(session(id: nil, session_id: "u1", kind: "interactive", name: "shell",
        cwd: "/srv/app", job_state: nil), nil)
      expect(r.matches?("shell")).to be(true)
      expect(r.matches?("app")).to be(true)
      expect(r.matches?("opensearch")).to be(false)
    end
  end

  it "answers nil for every reader when no poll has recorded the session yet" do
    r = row(session(id: "a"), nil)
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
    expect(row(session(id: "a"), nil)).to be_selectable
    expect(row(session(id: nil, session_id: nil, kind: "interactive"), nil)).not_to be_selectable
  end

  it "reads the entry through its accessors" do
    r = row(session(id: "a"), {"wake_at" => ClaudeInbox::Store::UNTIL_WOKEN, "state_since" => 5, "pinned" => true, "pinned_at" => 6, "reap_failed_at" => 7})
    expect(r.wake_at).to eq(ClaudeInbox::Store::UNTIL_WOKEN)
    expect(r.parked?).to be(true)
    expect(r.state_since).to eq(5)
    expect(r.pinned?).to be(true)
    expect(r.pinned_at).to eq(6)
    expect(r.reap_failed_at).to eq(7)
  end

  describe "reap rule" do
    let(:quiet) { {"last_state" => "done", "state_since" => now.to_i - ClaudeInbox::Store::REAP_AFTER - 1} }
    let(:recent) { {"last_state" => "done", "state_since" => now.to_i - ClaudeInbox::Store::REAP_AFTER + 60} }

    it "reaps a finished session quiet for longer than REAP_AFTER" do
      expect(row(session(id: "a", state: "done"), quiet)).to be_reapable(now.to_i)
    end

    it "leaves one that has been quiet for less" do
      expect(row(session(id: "a", state: "done"), recent)).not_to be_reapable(now.to_i)
    end

    it "reaps on idle time alone, where settling waits on the pull request" do
      s = session(id: "a", state: "done", prs: [pr("DRAFT")])
      expect(row(s, quiet).settled?).to be(false)
      expect(row(s, quiet)).to be_reapable(now.to_i)
    end

    it "reaps a long-dead failure, which never settles" do
      s = session(id: "a", state: "failed")
      expect(row(s, quiet).settled?).to be(false)
      expect(row(s, quiet)).to be_reapable(now.to_i)
    end

    it "never reaps a working session" do
      expect(row(session(id: "a", state: "working"), quiet)).not_to be_reapable(now.to_i)
    end

    it "never reaps one that still has a process" do
      expect(row(session(id: "a", state: "done", pid: 4321), quiet)).not_to be_reapable(now.to_i)
    end

    it "never reaps a pin or a snooze, however long it has been parked" do
      expect(row(session(id: "a", state: "done"), quiet.merge("pinned" => true))).not_to be_reapable(now.to_i)
      expect(row(session(id: "a", state: "done"), quiet.merge("wake_at" => ClaudeInbox::Store::UNTIL_WOKEN, "snoozed_at" => 1))).not_to be_reapable(now.to_i)
    end

    it "reaps once an elapsed snooze has woken it" do
      woken = quiet.merge("wake_at" => now.to_i - 60, "snoozed_at" => now.to_i - 120)
      expect(row(session(id: "a", state: "done"), woken)).to be_reapable(now.to_i)
    end

    it "never reaps a session there is no id to reap with" do
      s = session(id: nil, kind: "interactive", state: nil, status: "idle", session_id: "u9")
      expect(row(s, quiet)).not_to be_reapable(now.to_i)
    end

    it "never reaps a session it has no entry for" do
      expect(row(session(id: "a", state: "done"), nil)).not_to be_reapable(now.to_i)
    end
  end
end
