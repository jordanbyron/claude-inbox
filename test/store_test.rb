# frozen_string_literal: true

require_relative "test_helper"

class StoreRulesTest < Minitest::Test
  include Fixtures

  Store = ClaudeInbox::Store
  NOW = Time.at(1_789_600_000)

  def sections(sessions, entries = {}, now = NOW) = Store.sectionize(sessions, entries, now)

  def ids(rows) = rows.map(&:id)

  # --- sectioning ---------------------------------------------------------

  def test_blocked_and_failed_need_you
    sess = [session(id: "a", state: "blocked"), session(id: "b", state: "failed"), session(id: "c", state: "working")]
    sec = sections(sess)
    assert_equal %w[a b].sort, ids(sec.needs_you).sort
    assert_equal %w[c], ids(sec.working)
  end

  def test_interactive_rows_land_in_working_and_are_not_selectable
    sec = sections([session(id: nil, kind: "interactive", state: nil, status: "busy")])
    assert_equal 1, sec.working.size
    refute sec.working.first.selectable?
  end

  def test_fresh_done_session_stays_in_working_until_settled
    entries = {"a" => {"last_state" => "done", "state_since" => NOW.to_i - 60}}
    sec = sections([session(id: "a", state: "done")], entries)
    assert_equal %w[a], ids(sec.working)
    assert_empty sec.settled
  end

  # --- settle -------------------------------------------------------------

  def test_done_and_quiet_settles
    entries = {"a" => {"last_state" => "done", "state_since" => NOW.to_i - Store::SETTLE_AFTER - 1}}
    sec = sections([session(id: "a", state: "done")], entries)
    assert_equal %w[a], ids(sec.settled)
  end

  def test_stopped_and_quiet_settles
    entries = {"a" => {"last_state" => "stopped", "state_since" => NOW.to_i - 3600}}
    assert_equal %w[a], ids(sections([session(id: "a", state: "stopped")], entries).settled)
  end

  def test_failed_never_settles
    entries = {"a" => {"last_state" => "failed", "state_since" => NOW.to_i - 86_400 * 3}}
    sec = sections([session(id: "a", state: "failed")], entries)
    assert_empty sec.settled
    assert_equal %w[a], ids(sec.needs_you)
  end

  def test_first_seen_finished_reaped_session_settles_immediately
    s = session(id: "a", state: "done", pid: nil, started_at: NOW - 86_400)
    entries = Store.merge_entries({}, [s], NOW)
    assert_equal %w[a], ids(sections([s], entries).settled)
  end

  def test_first_seen_finished_but_alive_session_does_not_settle
    s = session(id: "a", state: "done", pid: 123, status: "idle")
    entries = Store.merge_entries({}, [s], NOW)
    assert_equal %w[a], ids(sections([s], entries).working)
  end

  # --- snooze / wake ------------------------------------------------------

  def test_snoozed_session_hides_in_snoozed
    entries = {"a" => {"wake_at" => NOW.to_i + 900, "last_state" => "working"}}
    sec = sections([session(id: "a", state: "working")], entries)
    assert_equal %w[a], ids(sec.snoozed)
    assert_empty sec.working
  end

  def test_snoozed_then_blocked_wakes
    entries = {"a" => {"wake_at" => NOW.to_i + 900, "snoozed_at" => NOW.to_i - 300, "last_state" => "working", "state_since" => NOW.to_i - 400}}
    entries = Store.merge_entries(entries, [session(id: "a", state: "blocked")], NOW)
    sec = sections([session(id: "a", state: "blocked")], entries)
    assert_equal %w[a], ids(sec.needs_you)
    assert_empty sec.snoozed
    refute entries["a"].key?("wake_at")
  end

  def test_snoozed_then_failed_wakes
    entries = {"a" => {"wake_at" => Store::UNTIL_WOKEN, "snoozed_at" => NOW.to_i - 300, "last_state" => "working", "state_since" => NOW.to_i - 400}}
    entries = Store.merge_entries(entries, [session(id: "a", state: "failed")], NOW)
    assert_equal %w[a], ids(sections([session(id: "a", state: "failed")], entries).needs_you)
  end

  def test_snoozing_an_already_blocked_session_sticks
    entries = {"a" => {"last_state" => "blocked", "state_since" => NOW.to_i - 600}}
    entries = Store.merge_entries(entries, [session(id: "a", state: "blocked")], NOW)
    store_entries = entries.merge("a" => entries["a"].merge("wake_at" => NOW.to_i + 900, "snoozed_at" => NOW.to_i))
    later = Store.merge_entries(store_entries, [session(id: "a", state: "blocked")], NOW + 60)
    sec = sections([session(id: "a", state: "blocked")], later, NOW + 60)
    assert_equal %w[a], ids(sec.snoozed)
    assert_empty sec.needs_you
  end

  def test_wake_at_elapsed_wakes
    entries = {"a" => {"wake_at" => NOW.to_i - 1, "last_state" => "working"}}
    sec = sections([session(id: "a", state: "working")], entries)
    assert_equal %w[a], ids(sec.working)
  end

  def test_until_woken_never_elapses
    entries = {"a" => {"wake_at" => Store::UNTIL_WOKEN, "last_state" => "working"}}
    sec = sections([session(id: "a", state: "working")], entries, NOW + 86_400 * 30)
    assert_equal %w[a], ids(sec.snoozed)
    assert sec.snoozed.first.parked?
  end

  def test_snoozed_sorts_by_wake_at_with_parked_last
    entries = {
      "a" => {"wake_at" => Store::UNTIL_WOKEN},
      "b" => {"wake_at" => NOW.to_i + 3600},
      "c" => {"wake_at" => NOW.to_i + 60}
    }
    sess = %w[a b c].map { |i| session(id: i) }
    assert_equal %w[c b a], ids(sections(sess, entries).snoozed)
  end

  def test_snoozed_done_session_settles_after_wake_only
    # snoozed wins over settle while the timer is live
    entries = {"a" => {"wake_at" => NOW.to_i + 900, "last_state" => "done", "state_since" => NOW.to_i - 3600}}
    assert_equal %w[a], ids(sections([session(id: "a", state: "done")], entries).snoozed)
  end

  # --- merge_entries ------------------------------------------------------

  def test_merge_bumps_state_since_only_on_change
    t0 = NOW
    e = Store.merge_entries({}, [session(id: "a", state: "working")], t0)
    assert_equal t0.to_i, e["a"]["state_since"]
    e = Store.merge_entries(e, [session(id: "a", state: "working")], t0 + 100)
    assert_equal t0.to_i, e["a"]["state_since"]
    e = Store.merge_entries(e, [session(id: "a", state: "done")], t0 + 200)
    assert_equal (t0 + 200).to_i, e["a"]["state_since"]
    assert_equal "done", e["a"]["last_state"]
  end

  def test_merge_clears_elapsed_snooze
    entries = {"a" => {"wake_at" => NOW.to_i - 1, "snoozed_at" => NOW.to_i - 901, "last_state" => "working"}}
    e = Store.merge_entries(entries, [session(id: "a", state: "working")], NOW)
    refute e["a"].key?("wake_at")
    refute e["a"].key?("snoozed_at")
  end

  def test_merge_clears_snooze_when_blocked
    entries = {"a" => {"wake_at" => Store::UNTIL_WOKEN, "snoozed_at" => NOW.to_i - 10, "last_state" => "working", "state_since" => NOW.to_i - 20}}
    e = Store.merge_entries(entries, [session(id: "a", state: "blocked")], NOW)
    refute e["a"].key?("wake_at")
  end

  def test_merge_keeps_alias_and_prunes_stale
    entries = {
      "old" => {"alias" => "x", "last_seen" => NOW.to_i - Store::PRUNE_AFTER - 1},
      "kept" => {"alias" => "y", "last_seen" => NOW.to_i - 100}
    }
    e = Store.merge_entries(entries, [], NOW)
    refute e.key?("old")
    assert_equal "y", e["kept"]["alias"]
  end

  def test_merge_ignores_interactive_rows
    e = Store.merge_entries({}, [session(id: nil, kind: "interactive")], NOW)
    assert_empty e
  end

  # --- snooze_until -------------------------------------------------------

  def test_snooze_until_targets
    now = Time.new(2026, 9, 16, 20, 30, 0)
    assert_equal now.to_i + 900, Store.snooze_until(:m15, now)
    assert_equal now.to_i + 3600, Store.snooze_until(:h1, now)
    assert_equal Time.new(2026, 9, 17, 9, 0, 0).to_i, Store.snooze_until(:tomorrow_9am, now)
    assert_equal Time.new(2026, 9, 16, 9, 0, 0).to_i, Store.snooze_until(:tomorrow_9am, Time.new(2026, 9, 16, 3, 0, 0))
    assert_equal Store::UNTIL_WOKEN, Store.snooze_until(:until_woken, now)
  end

  # --- fixture end to end -------------------------------------------------

  def test_fixture_sections
    sessions = fixture_sessions
    now = Time.at(1_789_604_500)
    entries = Store.merge_entries({}, sessions, now)
    sec = Store.sectionize(sessions, entries, now)
    assert_equal %w[f23c8673], ids(sec.needs_you)
    assert_equal [nil, "823b882f"], ids(sec.working) # interactive + done-but-alive
    assert_equal 4, sec.settled.size
  end
end

class StorePersistenceTest < Minitest::Test
  include Fixtures

  def test_round_trips_through_file_atomically
    Dir.mktmpdir do |dir|
      path = File.join(dir, "nested", "state.json")
      clock = -> { Time.at(1_789_600_000) }
      store = ClaudeInbox::Store.new(path: path, clock: clock)
      store.update([session(id: "a")])
      store.snooze("a", :h1)
      store.set_alias("a", "flaky test fix")

      data = JSON.parse(File.read(path))
      assert_equal 1, data["version"]
      assert_equal 1_789_603_600, data["sessions"]["a"]["wake_at"]
      assert_equal "flaky test fix", data["sessions"]["a"]["alias"]
      assert_empty Dir.glob(File.join(dir, "nested", ".state.*.tmp"))

      reloaded = ClaudeInbox::Store.new(path: path, clock: clock)
      reloaded.update([session(id: "a")])
      assert_equal %w[a], reloaded.sections.snoozed.map(&:id)
      reloaded.wake("a")
      assert_empty reloaded.sections.snoozed
    end
  end
end
