# frozen_string_literal: true

RSpec.describe ClaudeInbox::Store::Entry do
  let(:now) { Time.at(1_789_600_000) }

  describe "readers" do
    it "names every key state.json holds" do
      h = {"alias" => "x", "pr" => "u", "wake_at" => 1, "snoozed_at" => 2, "last_state" => "done", "state_since" => 3,
           "last_seen" => 4, "pinned" => true, "pinned_at" => 5, "settled_at" => 6, "acknowledged_at" => 7,
           "revived_at" => 8, "reap_failed_at" => 9, "reap_error" => "no"}
      e = described_class.new(h)
      expect(e.alias_name).to eq("x")
      expect(e.pr).to eq("u")
      expect(e.wake_at).to eq(1)
      expect(e.snoozed_at).to eq(2)
      expect(e.last_state).to eq("done")
      expect(e.state_since).to eq(3)
      expect(e.last_seen).to eq(4)
      expect(e.pinned?).to be(true)
      expect(e.pinned_at).to eq(5)
      expect(e.settled_at).to eq(6)
      expect(e.acknowledged_at).to eq(7)
      expect(e.revived_at).to eq(8)
      expect(e.reap_failed_at).to eq(9)
      expect(e.reap_error).to eq("no")
      expect(e.to_h).to equal(h)
    end

    it "answers nil or false for an empty entry" do
      e = described_class.new({})
      expect(e.alias_name).to be_nil
      expect(e.wake_at).to be_nil
      expect(e.pinned?).to be(false)
      expect(e.parked?).to be(false)
    end

    it "is parked only on an until-woken snooze" do
      expect(described_class.new("wake_at" => ClaudeInbox::Store::UNTIL_WOKEN)).to be_parked
      expect(described_class.new("wake_at" => now.to_i)).not_to be_parked
    end

    it "is stale once unseen for PRUNE_AFTER, and never before it has been seen" do
      expect(described_class.new("last_seen" => now.to_i - ClaudeInbox::Store::PRUNE_AFTER - 1).stale?(now)).to be(true)
      expect(described_class.new("last_seen" => now.to_i - ClaudeInbox::Store::PRUNE_AFTER).stale?(now)).to be(false)
      expect(described_class.new({}).stale?(now)).to be_nil
    end
  end

  describe ".blank" do
    it "carries only a state_since of now" do
      expect(described_class.blank(now).to_h).to eq({"state_since" => now.to_i})
    end
  end

  describe ".first_seen" do
    it "seeds state_since from started_at for a finished session whose process was reaped" do
      s = session(id: "a", state: "done", pid: nil, started_at: now - 86_400)
      expect(described_class.first_seen(s, now).to_h).to eq({"last_state" => "done", "state_since" => (now - 86_400).to_i})
    end

    it "seeds state_since from now for a finished session that is still alive, or a working one" do
      expect(described_class.first_seen(session(id: "a", state: "done", pid: 123, status: "idle"), now).state_since).to eq(now.to_i)
      expect(described_class.first_seen(session(id: "a", state: "working", pid: nil), now).state_since).to eq(now.to_i)
    end
  end

  describe "#observe" do
    it "seeds a first sighting and records last_seen" do
      e = described_class.observe(nil, session(id: "a"), now)
      expect(e.to_h).to eq({"last_state" => "working", "state_since" => now.to_i, "last_seen" => now.to_i})
    end

    it "bumps state_since only when the state changes" do
      e = described_class.observe(nil, session(id: "a"), now)
      e.observe(session(id: "a"), now + 100)
      expect(e.state_since).to eq(now.to_i)
      expect(e.last_seen).to eq((now + 100).to_i)
      e.observe(session(id: "a", state: "done"), now + 200)
      expect(e.state_since).to eq((now + 200).to_i)
      expect(e.last_state).to eq("done")
    end

    it "clears an elapsed snooze" do
      e = described_class.new("wake_at" => now.to_i - 1, "snoozed_at" => now.to_i - 901, "last_state" => "working").observe(session(id: "a"), now)
      expect(e.to_h).not_to include "wake_at"
      expect(e.to_h).not_to include "snoozed_at"
    end

    it "keeps a snooze that has not elapsed, and a parked one for ever" do
      e = described_class.new("wake_at" => now.to_i + 900, "snoozed_at" => now.to_i, "last_state" => "working").observe(session(id: "a"), now + 60)
      expect(e.wake_at).to eq(now.to_i + 900)
      parked = described_class.new("wake_at" => ClaudeInbox::Store::UNTIL_WOKEN, "snoozed_at" => now.to_i, "last_state" => "working").observe(session(id: "a"), now + 86_400 * 30)
      expect(parked.wake_at).to eq(ClaudeInbox::Store::UNTIL_WOKEN)
    end

    it "wakes a snooze when the session becomes blocked afterwards" do
      h = {"wake_at" => now.to_i + 900, "snoozed_at" => now.to_i - 300, "last_state" => "working", "state_since" => now.to_i - 400}
      e = described_class.new(h).observe(session(id: "a", state: "blocked"), now)
      expect(e.to_h).not_to include "wake_at"
      expect(e.to_h).not_to include "snoozed_at"
    end

    it "keeps a hand-settle while the session finishes, and lifts it on any other change" do
      h = {"settled_at" => now.to_i, "last_state" => "working", "state_since" => now.to_i - 60}
      expect(described_class.new(h.dup).observe(session(id: "a", state: "done"), now + 30).settled_at).to eq(now.to_i)
      expect(described_class.new(h.dup).observe(session(id: "a", state: "blocked"), now + 30).to_h).not_to include "settled_at"
    end

    it "lifts an acknowledge and a revive once the state changes" do
      h = {"acknowledged_at" => now.to_i, "revived_at" => now.to_i, "last_state" => "blocked", "state_since" => now.to_i - 60}
      same = described_class.new(h.dup).observe(session(id: "a", state: "blocked"), now + 30)
      expect(same.acknowledged_at).to eq(now.to_i)
      expect(same.revived_at).to eq(now.to_i)
      changed = described_class.new(h.dup).observe(session(id: "a", state: "working"), now + 30)
      expect(changed.to_h).not_to include "acknowledged_at"
      expect(changed.to_h).not_to include "revived_at"
    end

    it "returns itself, over the same hash" do
      h = {"last_state" => "working"}
      e = described_class.new(h)
      expect(e.observe(session(id: "a"), now)).to equal(e)
      expect(e.to_h).to equal(h)
    end
  end

  describe "mutators" do
    subject(:entry) { described_class.new({}) }

    it "snooze sets the wake time and when it was asked for" do
      entry.snooze(:h1, now)
      expect(entry.wake_at).to eq(now.to_i + 3600)
      expect(entry.snoozed_at).to eq(now.to_i)
      entry.snooze(:until_woken, now)
      expect(entry).to be_parked
    end

    it "wake clears the snooze and the hand-settle, and records the revive" do
      entry.snooze(:h1, now)
      entry.settle(now)
      entry.wake(now + 1)
      expect(entry.to_h).to eq({"revived_at" => now.to_i + 1})
    end

    it "settle clears the snooze and a prior revive" do
      entry.snooze(:h1, now)
      entry.wake(now)
      entry.settle(now + 1)
      expect(entry.to_h).to eq({"settled_at" => now.to_i + 1})
    end

    it "acknowledge stamps acknowledged_at" do
      entry.acknowledge(now)
      expect(entry.to_h).to eq({"acknowledged_at" => now.to_i})
    end

    it "toggle_pin pins with a time, then unpins clean" do
      entry.toggle_pin(now)
      expect(entry.to_h).to eq({"pinned" => true, "pinned_at" => now.to_i})
      expect(entry).to be_pinned
      entry.toggle_pin(now + 5)
      expect(entry.to_h).to eq({})
    end

    it "alias= and pr= set, and an empty value deletes the key" do
      entry.alias = "flaky"
      entry.pr = "https://github.com/o/r/pull/7"
      expect(entry.to_h).to eq({"alias" => "flaky", "pr" => "https://github.com/o/r/pull/7"})
      entry.alias = ""
      entry.pr = nil
      expect(entry.to_h).to eq({})
    end

    it "mark_reap_failed keeps the first line of the refusal" do
      entry.mark_reap_failed(now, "rm failed: worktree has unpushed commits\nmore")
      expect(entry.reap_failed_at).to eq(now.to_i)
      expect(entry.reap_error).to eq("rm failed: worktree has unpushed commits")
    end
  end

  describe ".snooze_until" do
    let(:evening) { Time.new(2026, 9, 16, 20, 30, 0) }

    it("15m") { expect(described_class.snooze_until(:m15, evening)).to eq(evening.to_i + 900) }
    it("1h") { expect(described_class.snooze_until(:h1, evening)).to eq(evening.to_i + 3600) }
    it("tomorrow 9am") { expect(described_class.snooze_until(:tomorrow_9am, evening)).to eq(Time.new(2026, 9, 17, 9).to_i) }
    it("today 9am when it is still early") { expect(described_class.snooze_until(:tomorrow_9am, Time.new(2026, 9, 16, 3))).to eq(Time.new(2026, 9, 16, 9).to_i) }
    it("until woken") { expect(described_class.snooze_until(:until_woken, evening)).to eq(ClaudeInbox::Store::UNTIL_WOKEN) }
    it("rejects anything else") { expect { described_class.snooze_until(:never, evening) }.to raise_error(ArgumentError) }
  end
end
