# frozen_string_literal: true

RSpec.describe ClaudeInbox::Store::Row do
  subject(:row) { described_class.new(session: session(**attrs), entry: entry && ClaudeInbox::Store::Entry.new(entry)) }

  let(:now) { Time.at(1_789_600_000) }
  let(:attrs) { {id: "a"} }
  let(:entry) { nil }

  context "with no alias" do
    let(:attrs) { {id: "a", name: "Thing", cwd: "/srv/Other"} }

    it "shows the session's name, and searches label or cwd" do
      expect(row.label).to eq("Thing")
      expect(row.alias_name).to be_nil
      expect(row.matches?("thing")).to be(true)
      expect(row.matches?("other")).to be(true)
      expect(row.matches?("zzz")).to be(false)
    end
  end

  context "with an alias" do
    let(:attrs) { {id: "a", name: "Thing"} }
    let(:entry) { {"alias" => "flaky"} }

    it "shows the alias over the session's name, and searches that instead" do
      expect(row.label).to eq("flaky")
      expect(row.matches?("flaky")).to be(true)
      expect(row.matches?("thing")).to be(false)
    end
  end

  describe "searching a session you cannot name" do
    context "with the prompt it was started with" do
      let(:attrs) do
        {id: "a", name: "SEAR-1594", cwd: "/srv/app",
         job_state: ClaudeInbox::JobState.new("intent" => "Restore the OpenSearch indexes in Sagemaker")}
      end

      it "searches the prompt the session was started with" do
        expect(row.matches?("opensearch")).to be(true)
        expect(row.matches?("sagemaker")).to be(true)
        expect(row.matches?("kubernetes")).to be(false)
      end
    end

    context "with a line it is showing about itself" do
      let(:attrs) do
        {id: "a", name: "SEAR-1594", state: "working",
         job_state: ClaudeInbox::JobState.new("detail" => "Reading the synonym-mode application")}
      end

      it "searches the line the session is showing about itself" do
        expect(row.matches?("synonym")).to be(true)
      end
    end

    context "with an interactive session" do
      let(:attrs) { {id: nil, session_id: "u1", kind: "interactive", name: "shell", cwd: "/srv/app", job_state: nil} }

      it "leaves an interactive session searchable by name and cwd alone" do
        expect(row.matches?("shell")).to be(true)
        expect(row.matches?("app")).to be(true)
        expect(row.matches?("opensearch")).to be(false)
      end
    end
  end

  it "answers nil for every reader when no poll has recorded the session yet" do
    expect(row.entry).to be_nil
    expect(row.wake_at).to be_nil
    expect(row.state_since).to be_nil
    expect(row.pinned_at).to be_nil
    expect(row.pinned?).to be_nil
    expect(row.parked?).to be_nil
    expect(row.reap_failed_at).to be_nil
    expect(row.section(now)).to eq(:active)
  end

  it "is selectable with a key" do
    expect(row).to be_selectable
  end

  context "with no key" do
    let(:attrs) { {id: nil, session_id: nil, kind: "interactive"} }

    it "is not selectable" do
      expect(row).not_to be_selectable
    end
  end

  context "with an entry" do
    let(:entry) { {"wake_at" => ClaudeInbox::Store::UNTIL_WOKEN, "state_since" => 5, "pinned" => true, "pinned_at" => 6, "reap_failed_at" => 7} }

    it "reads the entry through its accessors" do
      expect(row.wake_at).to eq(ClaudeInbox::Store::UNTIL_WOKEN)
      expect(row.parked?).to be(true)
      expect(row.state_since).to eq(5)
      expect(row.pinned?).to be(true)
      expect(row.pinned_at).to eq(6)
      expect(row.reap_failed_at).to eq(7)
    end
  end

  describe "reap rule" do
    let(:attrs) { {id: "a", state: "done"} }
    let(:entry) { {"last_state" => "done", "state_since" => now.to_i - ClaudeInbox::Store::REAP_AFTER - 1} }

    it "reaps a finished session quiet for longer than REAP_AFTER" do
      expect(row).to be_reapable(now.to_i)
    end

    context "when quiet for less" do
      let(:entry) { {"last_state" => "done", "state_since" => now.to_i - ClaudeInbox::Store::REAP_AFTER + 60} }

      it "leaves one that has been quiet for less" do
        expect(row).not_to be_reapable(now.to_i)
      end
    end

    context "with a draft PR" do
      let(:attrs) { {id: "a", state: "done", prs: [ClaudeInbox::PullRequest.new(number: 1, url: "https://github.com/o/r/pull/1", state: "DRAFT")]} }

      it "reaps on idle time alone, where settling waits on the pull request" do
        expect(row.settled?).to be(false)
        expect(row).to be_reapable(now.to_i)
      end
    end

    context "when failed" do
      let(:attrs) { {id: "a", state: "failed"} }

      it "reaps a long-dead failure, which never settles" do
        expect(row.settled?).to be(false)
        expect(row).to be_reapable(now.to_i)
      end
    end

    context "when working" do
      let(:attrs) { {id: "a", state: "working"} }

      it "never reaps a working session" do
        expect(row).not_to be_reapable(now.to_i)
      end
    end

    context "with a process" do
      let(:attrs) { {id: "a", state: "done", pid: 4321} }

      it "never reaps one that still has a process" do
        expect(row).not_to be_reapable(now.to_i)
      end
    end

    context "when pinned" do
      let(:entry) { super().merge("pinned" => true) }

      it "never reaps a pin, however long it has been parked" do
        expect(row).not_to be_reapable(now.to_i)
      end
    end

    context "when snoozed until woken" do
      let(:entry) { super().merge("wake_at" => ClaudeInbox::Store::UNTIL_WOKEN, "snoozed_at" => 1) }

      it "never reaps a snooze, however long it has been parked" do
        expect(row).not_to be_reapable(now.to_i)
      end
    end

    context "when an elapsed snooze has woken it" do
      let(:entry) { super().merge("wake_at" => now.to_i - 60, "snoozed_at" => now.to_i - 120) }

      it "reaps once an elapsed snooze has woken it" do
        expect(row).to be_reapable(now.to_i)
      end
    end

    context "with no id" do
      let(:attrs) { {id: nil, kind: "interactive", state: nil, status: "idle", session_id: "u9"} }

      it "never reaps a session there is no id to reap with" do
        expect(row).not_to be_reapable(now.to_i)
      end
    end

    context "with no entry" do
      let(:entry) { nil }

      it "never reaps a session it has no entry for" do
        expect(row).not_to be_reapable(now.to_i)
      end
    end
  end
end
