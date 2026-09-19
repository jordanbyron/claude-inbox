# frozen_string_literal: true

require_relative "../test_helper"

Store = ClaudeInbox::Store unless defined?(Store)
Entry = ClaudeInbox::Store::Entry

describe ClaudeInbox::Store::Entry do
  let(:now) { Time.at(1_789_600_000) }

  describe "readers" do
    it "names every key state.json holds" do
      h = {"alias" => "x", "pr" => "u", "wake_at" => 1, "snoozed_at" => 2, "last_state" => "done", "state_since" => 3,
           "last_seen" => 4, "pinned" => true, "pinned_at" => 5, "settled_at" => 6, "acknowledged_at" => 7,
           "revived_at" => 8, "reap_failed_at" => 9, "reap_error" => "no"}
      e = Entry.new(h)
      _(e.alias_name).must_equal "x"
      _(e.pr).must_equal "u"
      _(e.wake_at).must_equal 1
      _(e.snoozed_at).must_equal 2
      _(e.last_state).must_equal "done"
      _(e.state_since).must_equal 3
      _(e.last_seen).must_equal 4
      _(e.pinned?).must_equal true
      _(e.pinned_at).must_equal 5
      _(e.settled_at).must_equal 6
      _(e.acknowledged_at).must_equal 7
      _(e.revived_at).must_equal 8
      _(e.reap_failed_at).must_equal 9
      _(e.reap_error).must_equal "no"
      _(e.to_h).must_be_same_as h
    end

    it "answers nil or false for an empty entry" do
      e = Entry.new({})
      _(e.alias_name).must_be_nil
      _(e.wake_at).must_be_nil
      _(e.pinned?).must_equal false
      _(e.parked?).must_equal false
    end

    it "is parked only on an until-woken snooze" do
      _(Entry.new("wake_at" => Store::UNTIL_WOKEN)).must_be :parked?
      _(Entry.new("wake_at" => now.to_i)).wont_be :parked?
    end

    it "is stale once unseen for PRUNE_AFTER, and never before it has been seen" do
      _(Entry.new("last_seen" => now.to_i - Store::PRUNE_AFTER - 1).stale?(now)).must_equal true
      _(Entry.new("last_seen" => now.to_i - Store::PRUNE_AFTER).stale?(now)).must_equal false
      _(Entry.new({}).stale?(now)).must_be_nil
    end
  end

  describe ".blank" do
    it "carries only a state_since of now" do
      _(Entry.blank(now).to_h).must_equal({"state_since" => now.to_i})
    end
  end

  describe ".first_seen" do
    it "seeds state_since from started_at for a finished session whose process was reaped" do
      s = session(id: "a", state: "done", pid: nil, started_at: now - 86_400)
      _(Entry.first_seen(s, now).to_h).must_equal({"last_state" => "done", "state_since" => (now - 86_400).to_i})
    end

    it "seeds state_since from now for a finished session that is still alive, or a working one" do
      _(Entry.first_seen(session(id: "a", state: "done", pid: 123, status: "idle"), now).state_since).must_equal now.to_i
      _(Entry.first_seen(session(id: "a", state: "working", pid: nil), now).state_since).must_equal now.to_i
    end
  end

  describe "#observe" do
    it "seeds a first sighting and records last_seen" do
      e = Entry.observe(nil, session(id: "a"), now)
      _(e.to_h).must_equal({"last_state" => "working", "state_since" => now.to_i, "last_seen" => now.to_i})
    end

    it "bumps state_since only when the state changes" do
      e = Entry.observe(nil, session(id: "a"), now)
      e.observe(session(id: "a"), now + 100)
      _(e.state_since).must_equal now.to_i
      _(e.last_seen).must_equal (now + 100).to_i
      e.observe(session(id: "a", state: "done"), now + 200)
      _(e.state_since).must_equal (now + 200).to_i
      _(e.last_state).must_equal "done"
    end

    it "clears an elapsed snooze" do
      e = Entry.new("wake_at" => now.to_i - 1, "snoozed_at" => now.to_i - 901, "last_state" => "working").observe(session(id: "a"), now)
      _(e.to_h).wont_include "wake_at"
      _(e.to_h).wont_include "snoozed_at"
    end

    it "keeps a snooze that has not elapsed, and a parked one for ever" do
      e = Entry.new("wake_at" => now.to_i + 900, "snoozed_at" => now.to_i, "last_state" => "working").observe(session(id: "a"), now + 60)
      _(e.wake_at).must_equal now.to_i + 900
      parked = Entry.new("wake_at" => Store::UNTIL_WOKEN, "snoozed_at" => now.to_i, "last_state" => "working").observe(session(id: "a"), now + 86_400 * 30)
      _(parked.wake_at).must_equal Store::UNTIL_WOKEN
    end

    it "wakes a snooze when the session becomes blocked afterwards" do
      h = {"wake_at" => now.to_i + 900, "snoozed_at" => now.to_i - 300, "last_state" => "working", "state_since" => now.to_i - 400}
      e = Entry.new(h).observe(session(id: "a", state: "blocked"), now)
      _(e.to_h).wont_include "wake_at"
      _(e.to_h).wont_include "snoozed_at"
    end

    it "keeps a hand-settle while the session finishes, and lifts it on any other change" do
      h = {"settled_at" => now.to_i, "last_state" => "working", "state_since" => now.to_i - 60}
      _(Entry.new(h.dup).observe(session(id: "a", state: "done"), now + 30).settled_at).must_equal now.to_i
      _(Entry.new(h.dup).observe(session(id: "a", state: "blocked"), now + 30).to_h).wont_include "settled_at"
    end

    it "lifts an acknowledge and a revive once the state changes" do
      h = {"acknowledged_at" => now.to_i, "revived_at" => now.to_i, "last_state" => "blocked", "state_since" => now.to_i - 60}
      same = Entry.new(h.dup).observe(session(id: "a", state: "blocked"), now + 30)
      _(same.acknowledged_at).must_equal now.to_i
      _(same.revived_at).must_equal now.to_i
      changed = Entry.new(h.dup).observe(session(id: "a", state: "working"), now + 30)
      _(changed.to_h).wont_include "acknowledged_at"
      _(changed.to_h).wont_include "revived_at"
    end

    it "returns itself, over the same hash" do
      h = {"last_state" => "working"}
      e = Entry.new(h)
      _(e.observe(session(id: "a"), now)).must_be_same_as e
      _(e.to_h).must_be_same_as h
    end
  end

  describe "mutators" do
    let(:entry) { Entry.new({}) }

    it "snooze sets the wake time and when it was asked for" do
      entry.snooze(:h1, now)
      _(entry.wake_at).must_equal now.to_i + 3600
      _(entry.snoozed_at).must_equal now.to_i
      entry.snooze(:until_woken, now)
      _(entry).must_be :parked?
    end

    it "wake clears the snooze and the hand-settle, and records the revive" do
      entry.snooze(:h1, now)
      entry.settle(now)
      entry.wake(now + 1)
      _(entry.to_h).must_equal({"revived_at" => now.to_i + 1})
    end

    it "settle clears the snooze and a prior revive" do
      entry.snooze(:h1, now)
      entry.wake(now)
      entry.settle(now + 1)
      _(entry.to_h).must_equal({"settled_at" => now.to_i + 1})
    end

    it "acknowledge stamps acknowledged_at" do
      entry.acknowledge(now)
      _(entry.to_h).must_equal({"acknowledged_at" => now.to_i})
    end

    it "toggle_pin pins with a time, then unpins clean" do
      entry.toggle_pin(now)
      _(entry.to_h).must_equal({"pinned" => true, "pinned_at" => now.to_i})
      _(entry).must_be :pinned?
      entry.toggle_pin(now + 5)
      _(entry.to_h).must_equal({})
    end

    it "alias= and pr= set, and an empty value deletes the key" do
      entry.alias = "flaky"
      entry.pr = "https://github.com/o/r/pull/7"
      _(entry.to_h).must_equal({"alias" => "flaky", "pr" => "https://github.com/o/r/pull/7"})
      entry.alias = ""
      entry.pr = nil
      _(entry.to_h).must_equal({})
    end

    it "mark_reap_failed keeps the first line of the refusal" do
      entry.mark_reap_failed(now, "rm failed: worktree has unpushed commits\nmore")
      _(entry.reap_failed_at).must_equal now.to_i
      _(entry.reap_error).must_equal "rm failed: worktree has unpushed commits"
    end
  end

  describe ".snooze_until" do
    let(:evening) { Time.new(2026, 9, 16, 20, 30, 0) }

    it("15m") { _(Entry.snooze_until(:m15, evening)).must_equal evening.to_i + 900 }
    it("1h") { _(Entry.snooze_until(:h1, evening)).must_equal evening.to_i + 3600 }
    it("tomorrow 9am") { _(Entry.snooze_until(:tomorrow_9am, evening)).must_equal Time.new(2026, 9, 17, 9).to_i }
    it("today 9am when it is still early") { _(Entry.snooze_until(:tomorrow_9am, Time.new(2026, 9, 16, 3))).must_equal Time.new(2026, 9, 16, 9).to_i }
    it("until woken") { _(Entry.snooze_until(:until_woken, evening)).must_equal Store::UNTIL_WOKEN }
    it("rejects anything else") { _ { Entry.snooze_until(:never, evening) }.must_raise ArgumentError }
  end
end
