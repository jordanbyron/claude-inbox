# frozen_string_literal: true

Store = ClaudeInbox::Store unless defined?(Store)

RSpec.describe ClaudeInbox::Store::Row do
  let(:now) { Time.at(1_789_600_000) }

  def row(s, entry) = Store::Row.new(session: s, entry: entry && Store::Entry.new(entry))

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
    def job(**h) = ClaudeInbox::JobState.new(h.transform_keys(&:to_s))

    it "searches the prompt the session was started with" do
      r = row(session(id: "a", name: "SEAR-1594", cwd: "/srv/app",
        job_state: job(intent: "Restore the OpenSearch indexes in Sagemaker")), nil)
      expect(r.matches?("opensearch")).to be(true)
      expect(r.matches?("sagemaker")).to be(true)
      expect(r.matches?("kubernetes")).to be(false)
    end

    it "searches the line the session is showing about itself" do
      r = row(session(id: "a", name: "SEAR-1594", state: "working",
        job_state: job(detail: "Reading the synonym-mode application")), nil)
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
    r = row(session(id: "a"), {"wake_at" => Store::UNTIL_WOKEN, "state_since" => 5, "pinned" => true, "pinned_at" => 6, "reap_failed_at" => 7})
    expect(r.wake_at).to eq(Store::UNTIL_WOKEN)
    expect(r.parked?).to be(true)
    expect(r.state_since).to eq(5)
    expect(r.pinned?).to be(true)
    expect(r.pinned_at).to eq(6)
    expect(r.reap_failed_at).to eq(7)
  end

  describe "reap rule" do
    def reapable?(s, entry) = row(s, entry).reapable?(now.to_i)

    def draft_pr = ClaudeInbox::PullRequest.new(number: 1, url: "https://github.com/o/r/pull/1", state: "DRAFT")

    let(:quiet) { {"last_state" => "done", "state_since" => now.to_i - Store::REAP_AFTER - 1} }
    let(:recent) { {"last_state" => "done", "state_since" => now.to_i - Store::REAP_AFTER + 60} }

    it "reaps a finished session quiet for longer than REAP_AFTER" do
      expect(reapable?(session(id: "a", state: "done"), quiet)).to be(true)
    end

    it "leaves one that has been quiet for less" do
      expect(reapable?(session(id: "a", state: "done"), recent)).to be(false)
    end

    it "reaps on idle time alone, where settling waits on the pull request" do
      s = session(id: "a", state: "done", prs: [draft_pr])
      expect(row(s, quiet).settled?).to be(false)
      expect(reapable?(s, quiet)).to be(true)
    end

    it "reaps a long-dead failure, which never settles" do
      s = session(id: "a", state: "failed")
      expect(row(s, quiet).settled?).to be(false)
      expect(reapable?(s, quiet)).to be(true)
    end

    it "never reaps a working session" do
      expect(reapable?(session(id: "a", state: "working"), quiet)).to be(false)
    end

    it "never reaps one that still has a process" do
      expect(reapable?(session(id: "a", state: "done", pid: 4321), quiet)).to be(false)
    end

    it "never reaps a pin or a snooze, however long it has been parked" do
      expect(reapable?(session(id: "a", state: "done"), quiet.merge("pinned" => true))).to be(false)
      expect(reapable?(session(id: "a", state: "done"), quiet.merge("wake_at" => Store::UNTIL_WOKEN, "snoozed_at" => 1))).to be(false)
    end

    it "reaps once an elapsed snooze has woken it" do
      woken = quiet.merge("wake_at" => now.to_i - 60, "snoozed_at" => now.to_i - 120)
      expect(reapable?(session(id: "a", state: "done"), woken)).to be(true)
    end

    it "never reaps a session there is no id to reap with" do
      s = session(id: nil, kind: "interactive", state: nil, status: "idle", session_id: "u9")
      expect(reapable?(s, quiet)).to be(false)
    end

    it "never reaps a session it has no entry for" do
      expect(reapable?(session(id: "a", state: "done"), nil)).to be(false)
    end
  end
end
