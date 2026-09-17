# frozen_string_literal: true

require_relative "test_helper"

Store = ClaudeInbox::Store

describe Store do
  let(:now) { Time.at(1_789_600_000) }

  def sections(sessions, entries = {}, at = now) = Store.sectionize(sessions, entries, at)

  def ids(rows) = rows.map(&:id)

  describe "sectioning" do
    it "puts blocked and failed in Needs you" do
      sec = sections([session(id: "a", state: "blocked"), session(id: "b", state: "failed"), session(id: "c")])
      _(ids(sec.needs_you).sort).must_equal %w[a b]
      _(ids(sec.working)).must_equal %w[c]
    end

    it "shows a busy terminal in Working, selectable but not actionable" do
      sec = sections([session(id: nil, kind: "interactive", state: nil, status: "busy", session_id: "uuid")])
      _(sec.working.size).must_equal 1
      _(sec.working.first).must_be :selectable?
      _(sec.working.first.session).wont_be :actionable?
      _(sec.working.first.session.effective_state).must_equal "working"
    end

    it "settles an idle remote session once quiet, and lets it snooze" do
      r = session(id: nil, kind: "interactive", state: nil, status: "idle", session_id: "u9", origin: :remote, started_at: now - 3600)
      entries = {"u9" => {"last_state" => "done", "state_since" => now.to_i - Store::SETTLE_AFTER - 1}}
      _(sections([r], entries).settled.map(&:key)).must_equal %w[u9]
      snoozed = {"u9" => {"wake_at" => now.to_i + 900, "last_state" => "done", "state_since" => now.to_i - 3600}}
      _(sections([r], snoozed).snoozed.map(&:key)).must_equal %w[u9]
    end

    it "tracks remote sessions in merge_entries by session uuid" do
      r = session(id: nil, kind: "interactive", state: nil, status: "busy", session_id: "u9", origin: :remote)
      e = Store.merge_entries({}, [r], now)
      _(e["u9"]["last_state"]).must_equal "working"
      e = Store.merge_entries(e, [r.dup.tap { |x| x.status = "idle" }], now + 60)
      _(e["u9"]["last_state"]).must_equal "done"
      _(e["u9"]["state_since"]).must_equal (now + 60).to_i
    end

    it "never settles or snoozes a terminal, even when idle for ages" do
      s = session(id: nil, kind: "interactive", state: nil, status: "idle", session_id: "uuid", started_at: now - 86_400)
      sec = sections([s], {}, now)
      _(sec.working.map(&:key)).must_equal %w[uuid]
      _(sec.settled).must_be_empty
    end

    it "keeps a freshly finished session in Working" do
      entries = {"a" => {"last_state" => "done", "state_since" => now.to_i - 60}}
      sec = sections([session(id: "a", state: "done")], entries)
      _(ids(sec.working)).must_equal %w[a]
      _(sec.settled).must_be_empty
    end
  end

  describe "pinning" do
    it "parks a pinned session at the top regardless of state" do
      entries = {"a" => {"pinned" => true, "pinned_at" => now.to_i, "last_state" => "working"}}
      sec = sections([session(id: "a")], entries)
      _(ids(sec.pinned)).must_equal %w[a]
      _(sec.working).must_be_empty
    end

    it "overrides needs_you, snoozed and settled" do
      entries = {"a" => {"pinned" => true, "pinned_at" => now.to_i, "last_state" => "blocked"}}
      _(ids(sections([session(id: "a", state: "blocked")], entries).pinned)).must_equal %w[a]

      entries = {"a" => {"pinned" => true, "pinned_at" => now.to_i, "wake_at" => now.to_i + 900, "last_state" => "working"}}
      _(ids(sections([session(id: "a")], entries).pinned)).must_equal %w[a]

      entries = {"a" => {"pinned" => true, "pinned_at" => now.to_i, "last_state" => "done", "state_since" => now.to_i - Store::SETTLE_AFTER - 1}}
      _(ids(sections([session(id: "a", state: "done")], entries).pinned)).must_equal %w[a]
    end

    it "sorts Pinned with the most recently pinned first" do
      entries = {"a" => {"pinned" => true, "pinned_at" => now.to_i - 60}, "b" => {"pinned" => true, "pinned_at" => now.to_i}}
      _(ids(sections(%w[a b].map { |i| session(id: i) }, entries).pinned)).must_equal %w[b a]
    end

    it "toggle_pin sets and clears pinned via the store" do
      clock = -> { now }
      Dir.mktmpdir do |dir|
        store = Store.new(path: File.join(dir, "state.json"), clock: clock)
        store.update([session(id: "a")])
        store.toggle_pin("a")
        _(store.sections.pinned.map(&:id)).must_equal %w[a]
        store.toggle_pin("a")
        _(store.sections.pinned).must_be_empty
      end
    end
  end

  describe "settle rule" do
    it "settles done + quiet" do
      entries = {"a" => {"last_state" => "done", "state_since" => now.to_i - Store::SETTLE_AFTER - 1}}
      _(ids(sections([session(id: "a", state: "done")], entries).settled)).must_equal %w[a]
    end

    it "settles stopped + quiet" do
      entries = {"a" => {"last_state" => "stopped", "state_since" => now.to_i - 3600}}
      _(ids(sections([session(id: "a", state: "stopped")], entries).settled)).must_equal %w[a]
    end

    it "never settles failed" do
      entries = {"a" => {"last_state" => "failed", "state_since" => now.to_i - 86_400 * 3}}
      sec = sections([session(id: "a", state: "failed")], entries)
      _(sec.settled).must_be_empty
      _(ids(sec.needs_you)).must_equal %w[a]
    end

    it "settles a first-seen finished session whose process was reaped" do
      s = session(id: "a", state: "done", pid: nil, started_at: now - 86_400)
      entries = Store.merge_entries({}, [s], now)
      _(ids(sections([s], entries).settled)).must_equal %w[a]
    end

    it "does not settle a first-seen finished session that is still alive" do
      s = session(id: "a", state: "done", pid: 123, status: "idle")
      entries = Store.merge_entries({}, [s], now)
      _(ids(sections([s], entries).working)).must_equal %w[a]
    end
  end

  describe "snooze and wake" do
    it "hides a snoozed session in Snoozed" do
      entries = {"a" => {"wake_at" => now.to_i + 900, "last_state" => "working"}}
      sec = sections([session(id: "a")], entries)
      _(ids(sec.snoozed)).must_equal %w[a]
      _(sec.working).must_be_empty
    end

    it "wakes when the session becomes blocked after the snooze" do
      entries = {"a" => {"wake_at" => now.to_i + 900, "snoozed_at" => now.to_i - 300, "last_state" => "working", "state_since" => now.to_i - 400}}
      entries = Store.merge_entries(entries, [session(id: "a", state: "blocked")], now)
      sec = sections([session(id: "a", state: "blocked")], entries)
      _(ids(sec.needs_you)).must_equal %w[a]
      _(sec.snoozed).must_be_empty
      _(entries["a"]).wont_include "wake_at"
    end

    it "wakes a parked session when it fails" do
      entries = {"a" => {"wake_at" => Store::UNTIL_WOKEN, "snoozed_at" => now.to_i - 300, "last_state" => "working", "state_since" => now.to_i - 400}}
      entries = Store.merge_entries(entries, [session(id: "a", state: "failed")], now)
      _(ids(sections([session(id: "a", state: "failed")], entries).needs_you)).must_equal %w[a]
    end

    it "keeps an already-blocked session snoozed" do
      entries = Store.merge_entries({"a" => {"last_state" => "blocked", "state_since" => now.to_i - 600}}, [session(id: "a", state: "blocked")], now)
      snoozed = entries.merge("a" => entries["a"].merge("wake_at" => now.to_i + 900, "snoozed_at" => now.to_i))
      later = Store.merge_entries(snoozed, [session(id: "a", state: "blocked")], now + 60)
      sec = sections([session(id: "a", state: "blocked")], later, now + 60)
      _(ids(sec.snoozed)).must_equal %w[a]
      _(sec.needs_you).must_be_empty
    end

    it "wakes when wake_at has elapsed" do
      entries = {"a" => {"wake_at" => now.to_i - 1, "last_state" => "working"}}
      _(ids(sections([session(id: "a")], entries).working)).must_equal %w[a]
    end

    it "never wakes until_woken on its own" do
      entries = {"a" => {"wake_at" => Store::UNTIL_WOKEN, "last_state" => "working"}}
      sec = sections([session(id: "a")], entries, now + 86_400 * 30)
      _(ids(sec.snoozed)).must_equal %w[a]
      _(sec.snoozed.first).must_be :parked?
    end

    it "sorts Snoozed by wake_at with parked last" do
      entries = {"a" => {"wake_at" => Store::UNTIL_WOKEN}, "b" => {"wake_at" => now.to_i + 3600}, "c" => {"wake_at" => now.to_i + 60}}
      _(ids(sections(%w[a b c].map { |i| session(id: i) }, entries).snoozed)).must_equal %w[c b a]
    end

    it "lets snooze win over settle while the timer is live" do
      entries = {"a" => {"wake_at" => now.to_i + 900, "last_state" => "done", "state_since" => now.to_i - 3600}}
      _(ids(sections([session(id: "a", state: "done")], entries).snoozed)).must_equal %w[a]
    end
  end

  describe ".merge_entries" do
    it "bumps state_since only when state changes" do
      e = Store.merge_entries({}, [session(id: "a")], now)
      _(e["a"]["state_since"]).must_equal now.to_i
      e = Store.merge_entries(e, [session(id: "a")], now + 100)
      _(e["a"]["state_since"]).must_equal now.to_i
      e = Store.merge_entries(e, [session(id: "a", state: "done")], now + 200)
      _(e["a"]["state_since"]).must_equal (now + 200).to_i
      _(e["a"]["last_state"]).must_equal "done"
    end

    it "clears an elapsed snooze" do
      entries = {"a" => {"wake_at" => now.to_i - 1, "snoozed_at" => now.to_i - 901, "last_state" => "working"}}
      e = Store.merge_entries(entries, [session(id: "a")], now)
      _(e["a"]).wont_include "wake_at"
      _(e["a"]).wont_include "snoozed_at"
    end

    it "keeps aliases and prunes stale entries" do
      entries = {
        "old" => {"alias" => "x", "last_seen" => now.to_i - Store::PRUNE_AFTER - 1},
        "kept" => {"alias" => "y", "last_seen" => now.to_i - 100}
      }
      e = Store.merge_entries(entries, [], now)
      _(e).wont_include "old"
      _(e["kept"]["alias"]).must_equal "y"
    end

    it "skips rows with no key at all" do
      _(Store.merge_entries({}, [session(id: nil, session_id: nil, kind: "interactive")], now)).must_be_empty
    end
  end

  describe ".snooze_until" do
    let(:evening) { Time.new(2026, 9, 16, 20, 30, 0) }

    it("15m") { _(Store.snooze_until(:m15, evening)).must_equal evening.to_i + 900 }
    it("1h") { _(Store.snooze_until(:h1, evening)).must_equal evening.to_i + 3600 }
    it("tomorrow 9am") { _(Store.snooze_until(:tomorrow_9am, evening)).must_equal Time.new(2026, 9, 17, 9).to_i }
    it("today 9am when it is still early") { _(Store.snooze_until(:tomorrow_9am, Time.new(2026, 9, 16, 3))).must_equal Time.new(2026, 9, 16, 9).to_i }
    it("until woken") { _(Store.snooze_until(:until_woken, evening)).must_equal Store::UNTIL_WOKEN }
  end

  describe "fixture end to end" do
    it "sections the captured sessions" do
      sessions = fixture_sessions
      at = Time.at(1_789_604_500)
      sec = Store.sectionize(sessions, Store.merge_entries({}, sessions, at), at)
      _(ids(sec.needs_you)).must_equal %w[f23c8673]
      _(ids(sec.working)).must_equal [nil, "823b882f"]
      _(sec.settled.size).must_equal 4
    end
  end

  describe "persistence" do
    it "round-trips through the file atomically" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "nested", "state.json")
        clock = -> { Time.at(1_789_600_000) }
        store = Store.new(path: path, clock: clock)
        store.update([session(id: "a")])
        store.snooze("a", :h1)
        store.set_alias("a", "flaky test fix")

        data = JSON.parse(File.read(path))
        _(data["version"]).must_equal 1
        _(data["sessions"]["a"]["wake_at"]).must_equal 1_789_603_600
        _(data["sessions"]["a"]["alias"]).must_equal "flaky test fix"
        _(Dir.glob(File.join(dir, "nested", ".state.*.tmp"))).must_be_empty

        reloaded = Store.new(path: path, clock: clock)
        reloaded.update([session(id: "a")])
        _(reloaded.sections.snoozed.map(&:id)).must_equal %w[a]
        reloaded.wake("a")
        _(reloaded.sections.snoozed).must_be_empty
      end
    end
  end
end
