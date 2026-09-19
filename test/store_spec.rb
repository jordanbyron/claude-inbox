# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

Store = ClaudeInbox::Store unless defined?(Store)

describe Store do
  let(:now) { Time.at(1_789_600_000) }

  def sections(sessions, entries = {}, at = now) = Store.sectionize(sessions, entries, at)

  def ids(rows) = rows.map(&:id)

  def pr(state) = ClaudeInbox::PullRequest.new(number: 1, url: "https://github.com/o/r/pull/1", state: state)

  describe "sectioning" do
    it "puts blocked and failed in Needs you" do
      sec = sections([session(id: "a", state: "blocked"), session(id: "b", state: "failed"), session(id: "c")])
      _(ids(sec.needs_you).sort).must_equal %w[a b]
      _(ids(sec.active)).must_equal %w[c]
    end

    it "shows a busy terminal in Active, selectable but not actionable" do
      sec = sections([session(id: nil, kind: "interactive", state: nil, status: "busy", session_id: "uuid")])
      _(sec.active.size).must_equal 1
      _(sec.active.first).must_be :selectable?
      _(sec.active.first.session).wont_be :actionable?
      _(sec.active.first.session.effective_state).must_equal "working"
    end

    it "settles an idle remote session with a resolved PR, and lets it snooze" do
      r = session(id: nil, kind: "interactive", state: nil, status: "idle", session_id: "u9", origin: :remote, started_at: now - 3600, prs: [pr("MERGED")])
      entries = {"u9" => {"last_state" => "done", "state_since" => now.to_i - 5}}
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
      _(sec.active.map(&:key)).must_equal %w[uuid]
      _(sec.settled).must_be_empty
    end

    it "keeps a freshly finished session in Active" do
      entries = {"a" => {"last_state" => "done", "state_since" => now.to_i - 60}}
      sec = sections([session(id: "a", state: "done")], entries)
      _(ids(sec.active)).must_equal %w[a]
      _(sec.settled).must_be_empty
    end

    it "never settles a finished session with no pull request, however long it has been quiet" do
      entries = {"a" => {"last_state" => "done", "state_since" => now.to_i - 86_400}}
      sec = sections([session(id: "a", state: "done")], entries)
      _(ids(sec.active)).must_equal %w[a]
      _(sec.settled).must_be_empty
    end

    it "keeps a finished session up while its PR is open, however long it has been quiet" do
      entries = {"a" => {"last_state" => "done", "state_since" => now.to_i - 86_400}}
      %w[OPEN DRAFT].each do |st|
        sec = sections([session(id: "a", state: "done", prs: [pr(st)])], entries)
        _(ids(sec.active)).must_equal %w[a]
      end
    end

    it "settles a finished session the moment its PR is merged or closed" do
      entries = {"a" => {"last_state" => "done", "state_since" => now.to_i - 5}}
      %w[MERGED CLOSED].each do |st|
        sec = sections([session(id: "a", state: "done", prs: [pr(st)])], entries)
        _(ids(sec.settled)).must_equal %w[a]
      end
    end

    it "waits for every known PR, and never settles on an unknown PR state" do
      entries = {"a" => {"last_state" => "done", "state_since" => now.to_i - 5}}
      _(ids(sections([session(id: "a", state: "done", prs: [pr("MERGED"), pr("OPEN")])], entries).active)).must_equal %w[a]
      _(ids(sections([session(id: "a", state: "done", prs: [pr(nil)])], entries).active)).must_equal %w[a]
      _(ids(sections([session(id: "a", state: "working", prs: [pr("MERGED")])], entries).active)).must_equal %w[a]
    end

    # A session that opens a PR ends its turn `blocked` on "anything need
    # changing before I flip it to ready?", never `done`. Merging answers it.
    it "settles a blocked session the moment its PR is merged or closed" do
      entries = {"a" => {"last_state" => "blocked", "state_since" => now.to_i - 5}}
      %w[MERGED CLOSED].each do |st|
        sec = sections([session(id: "a", state: "blocked", prs: [pr(st)])], entries)
        _(ids(sec.settled)).must_equal %w[a]
        _(sec.needs_you).must_be_empty
      end
    end

    it "keeps a blocked session in Needs you while its PR is still open" do
      entries = {"a" => {"last_state" => "blocked", "state_since" => now.to_i - 86_400}}
      %w[OPEN DRAFT].each do |st|
        _(ids(sections([session(id: "a", state: "blocked", prs: [pr(st)])], entries).needs_you)).must_equal %w[a]
      end
    end

    it "settles a merged blocked session you had already attached to" do
      entries = {"a" => {"last_state" => "blocked", "state_since" => now.to_i - 30, "acknowledged_at" => now.to_i - 10}}
      sec = sections([session(id: "a", state: "blocked", prs: [pr("MERGED")])], entries)
      _(ids(sec.settled)).must_equal %w[a]
      _(sec.active).must_be_empty
    end

    it "keeps a failed session loud even once its PR merged" do
      entries = {"a" => {"last_state" => "failed", "state_since" => now.to_i - 5}}
      sec = sections([session(id: "a", state: "failed", prs: [pr("MERGED")])], entries)
      _(ids(sec.needs_you)).must_equal %w[a]
      _(sec.settled).must_be_empty
    end
  end

  describe "pinning" do
    it "parks a pinned session at the top regardless of state" do
      entries = {"a" => {"pinned" => true, "pinned_at" => now.to_i, "last_state" => "working"}}
      sec = sections([session(id: "a")], entries)
      _(ids(sec.pinned)).must_equal %w[a]
      _(sec.active).must_be_empty
    end

    it "overrides needs_you, snoozed and settled" do
      entries = {"a" => {"pinned" => true, "pinned_at" => now.to_i, "last_state" => "blocked"}}
      _(ids(sections([session(id: "a", state: "blocked")], entries).pinned)).must_equal %w[a]

      entries = {"a" => {"pinned" => true, "pinned_at" => now.to_i, "wake_at" => now.to_i + 900, "last_state" => "working"}}
      _(ids(sections([session(id: "a")], entries).pinned)).must_equal %w[a]

      entries = {"a" => {"pinned" => true, "pinned_at" => now.to_i, "settled_at" => now.to_i, "last_state" => "done", "state_since" => now.to_i - 60}}
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
    it "settles a done session by hand" do
      entries = {"a" => {"settled_at" => now.to_i, "last_state" => "done", "state_since" => now.to_i - 60}}
      _(ids(sections([session(id: "a", state: "done")], entries).settled)).must_equal %w[a]
    end

    it "settles a stopped session with a resolved PR" do
      entries = {"a" => {"last_state" => "stopped", "state_since" => now.to_i - 3600}}
      _(ids(sections([session(id: "a", state: "stopped", prs: [pr("MERGED")])], entries).settled)).must_equal %w[a]
    end

    it "never settles failed" do
      entries = {"a" => {"last_state" => "failed", "state_since" => now.to_i - 86_400 * 3}}
      sec = sections([session(id: "a", state: "failed")], entries)
      _(sec.settled).must_be_empty
      _(ids(sec.needs_you)).must_equal %w[a]
    end

    it "seeds state_since from started_at for a first-seen finished session whose process was reaped" do
      s = session(id: "a", state: "done", pid: nil, started_at: now - 86_400)
      entries = Store.merge_entries({}, [s], now)
      _(entries["a"]["state_since"]).must_equal (now - 86_400).to_i
    end

    it "seeds state_since from now for a first-seen finished session that is still alive" do
      s = session(id: "a", state: "done", pid: 123, status: "idle")
      entries = Store.merge_entries({}, [s], now)
      _(entries["a"]["state_since"]).must_equal now.to_i
    end
  end

  describe "snooze and wake" do
    it "hides a snoozed session in Snoozed" do
      entries = {"a" => {"wake_at" => now.to_i + 900, "last_state" => "working"}}
      sec = sections([session(id: "a")], entries)
      _(ids(sec.snoozed)).must_equal %w[a]
      _(sec.active).must_be_empty
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
      _(ids(sections([session(id: "a")], entries).active)).must_equal %w[a]
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

    it "lets snooze win over settle even with a resolved PR" do
      entries = {"a" => {"wake_at" => now.to_i + 900, "last_state" => "done", "state_since" => now.to_i - 3600}}
      _(ids(sections([session(id: "a", state: "done", prs: [pr("MERGED")])], entries).snoozed)).must_equal %w[a]
    end
  end

  describe "hand settle" do
    it "settles a working session at once" do
      entries = {"a" => {"settled_at" => now.to_i, "last_state" => "working", "state_since" => now.to_i - 60}}
      _(ids(sections([session(id: "a")], entries).settled)).must_equal %w[a]
    end

    it "settles a blocked session and keeps it settled while still blocked" do
      entries = {"a" => {"settled_at" => now.to_i, "last_state" => "blocked", "state_since" => now.to_i - 60}}
      sec = sections([session(id: "a", state: "blocked")], entries, now + 3600)
      _(ids(sec.settled)).must_equal %w[a]
      _(sec.needs_you).must_be_empty
    end

    it "stays settled when the session finishes" do
      entries = {"a" => {"settled_at" => now.to_i, "last_state" => "working", "state_since" => now.to_i - 60}}
      later = Store.merge_entries(entries, [session(id: "a", state: "done")], now + 30)
      _(later["a"]["settled_at"]).must_equal now.to_i
      _(ids(sections([session(id: "a", state: "done")], later, now + 30).settled)).must_equal %w[a]
    end

    it "comes back when the session starts working again" do
      entries = {"a" => {"settled_at" => now.to_i, "last_state" => "blocked", "state_since" => now.to_i - 60}}
      later = Store.merge_entries(entries, [session(id: "a", state: "working")], now + 30)
      _(later["a"]).wont_include "settled_at"
      _(ids(sections([session(id: "a", state: "working")], later, now + 30).active)).must_equal %w[a]
    end

    it "comes back when the session becomes blocked afterwards" do
      entries = {"a" => {"settled_at" => now.to_i, "last_state" => "working", "state_since" => now.to_i - 60}}
      later = Store.merge_entries(entries, [session(id: "a", state: "blocked")], now + 30)
      _(later["a"]).wont_include "settled_at"
      _(ids(sections([session(id: "a", state: "blocked")], later, now + 30).needs_you)).must_equal %w[a]
    end

    it "is lifted by wake and replaces a snooze" do
      Dir.mktmpdir do |dir|
        store = Store.new(path: File.join(dir, "state.json"), clock: -> { now })
        store.snooze("a", :h1)
        store.settle("a")
        _(store.entry("a")).wont_include "wake_at"
        _(store.entry("a")["settled_at"]).must_equal now.to_i
        store.wake("a")
        _(store.entry("a")).wont_include "settled_at"
      end
    end

    it "takes hold again after a wake, even with no state change in between" do
      Dir.mktmpdir do |dir|
        store = Store.new(path: File.join(dir, "state.json"), clock: -> { now })
        store.update([session(id: "a", state: "blocked")])
        store.wake("a")
        store.settle("a")
        _(store.sections.settled.map(&:id)).must_equal %w[a]
      end
    end
  end

  describe "revive rule" do
    it "brings back a session settled by a resolved PR" do
      entries = {"a" => {"last_state" => "done", "state_since" => now.to_i - 5, "revived_at" => now.to_i}}
      sec = sections([session(id: "a", state: "done", prs: [pr("MERGED")])], entries)
      _(ids(sec.active)).must_equal %w[a]
      _(sec.settled).must_be_empty
    end

    it "brings back a hand-settled session that would otherwise stay settled" do
      entries = {"a" => {"settled_at" => now.to_i, "last_state" => "done", "state_since" => now.to_i - 60, "revived_at" => now.to_i + 1}}
      sec = sections([session(id: "a", state: "done")], entries)
      _(ids(sec.active)).must_equal %w[a]
      _(sec.settled).must_be_empty
    end

    it "routes a revived needs-you session to Needs You, not Active" do
      entries = {"a" => {"settled_at" => now.to_i, "last_state" => "blocked", "state_since" => now.to_i - 60, "revived_at" => now.to_i + 1}}
      sec = sections([session(id: "a", state: "blocked")], entries)
      _(ids(sec.needs_you)).must_equal %w[a]
    end

    it "clears once the state actually changes again" do
      entries = {"a" => {"last_state" => "blocked", "state_since" => now.to_i - 60, "revived_at" => now.to_i}}
      later = Store.merge_entries(entries, [session(id: "a", state: "working")], now + 30)
      _(later["a"]).wont_include "revived_at"
    end

    it "wake un-settles a resolved-PR session via the store" do
      Dir.mktmpdir do |dir|
        store = Store.new(path: File.join(dir, "state.json"), clock: -> { now })
        store.update([session(id: "a", state: "done", prs: [pr("MERGED")])])
        _(store.sections.settled.map(&:id)).must_equal %w[a]
        store.wake("a")
        _(store.sections.active.map(&:id)).must_equal %w[a]
      end
    end
  end

  describe "acknowledge rule" do
    it "moves an acknowledged blocked session to Active, not Settled" do
      entries = {"a" => {"acknowledged_at" => now.to_i, "last_state" => "blocked", "state_since" => now.to_i - 60}}
      sec = sections([session(id: "a", state: "blocked")], entries)
      _(ids(sec.active)).must_equal %w[a]
      _(sec.needs_you).must_be_empty
      _(sec.settled).must_be_empty
    end

    it "comes back to Needs You once the state changes again after acknowledging" do
      entries = {"a" => {"acknowledged_at" => now.to_i, "last_state" => "blocked", "state_since" => now.to_i - 60}}
      later = Store.merge_entries(entries, [session(id: "a", state: "working")], now + 30)
      later = Store.merge_entries(later, [session(id: "a", state: "blocked")], now + 60)
      _(later["a"]).wont_include "acknowledged_at"
      _(ids(sections([session(id: "a", state: "blocked")], later, now + 60).needs_you)).must_equal %w[a]
    end

    it "acknowledge sets acknowledged_at via the store" do
      Dir.mktmpdir do |dir|
        store = Store.new(path: File.join(dir, "state.json"), clock: -> { now })
        store.update([session(id: "a", state: "blocked")])
        store.acknowledge("a")
        _(store.entry("a")["acknowledged_at"]).must_equal now.to_i
        _(store.sections.active.map(&:id)).must_equal %w[a]
      end
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

  describe ".folded?" do
    it "folds a foldable section until it is expanded" do
      _(Store.folded?(:settled, {})).must_equal true
      _(Store.folded?(:settled, {settled: true})).must_equal false
      _(Store.folded?(:active, {})).must_equal false
    end
  end

  describe "fixture end to end" do
    it "sections the captured sessions" do
      sessions = fixture_sessions
      at = Time.at(1_789_604_500)
      sec = Store.sectionize(sessions, Store.merge_entries({}, sessions, at), at)
      _(ids(sec.needs_you)).must_equal %w[f23c8673]
      _(ids(sec.active)).must_equal [nil, "823b882f", "dcbc1d98", "b0b18338", "fbf5253a", "b03695b1"]
      _(sec.settled).must_be_empty
    end
  end

  describe "alias and pull request overrides" do
    let(:store) { Store.new(path: nil, clock: -> { now }).tap { |st| st.update([session(id: "a")]) } }

    it "reads back what set_alias and set_pr wrote, and nil once cleared" do
      _(store.alias_for("a")).must_be_nil
      _(store.pr_for("a")).must_be_nil

      store.set_alias("a", "flaky test fix")
      store.set_pr("a", "https://github.com/o/r/pull/7")
      _(store.alias_for("a")).must_equal "flaky test fix"
      _(store.pr_for("a")).must_equal "https://github.com/o/r/pull/7"

      store.set_alias("a", "")
      store.set_pr("a", "")
      _(store.alias_for("a")).must_be_nil
      _(store.pr_for("a")).must_be_nil
    end

    it "answers nil for a session it has never seen" do
      _(store.alias_for("nope")).must_be_nil
      _(store.pr_for("nope")).must_be_nil
    end
  end

  describe "row" do
    it "pairs a session with its entry, and carries the last refused reap" do
      store = Store.new(path: nil, clock: -> { now })
      s = session(id: "a")
      store.update([s])

      _(store.row(s).reap_failed_at).must_be_nil
      store.mark_reap_failed("a", "rm failed: worktree has unpushed commits\nmore")
      row = store.row(s)
      _(row.session).must_equal s
      _(row.reap_failed_at).must_equal now.to_i
      _(row.state_since).must_equal now.to_i
    end

    it "has no entry for a session with nothing to key on" do
      store = Store.new(path: nil, clock: -> { now })
      row = store.row(session(id: nil, session_id: nil, kind: "interactive"))
      _(row.entry).must_be_nil
      _(row.reap_failed_at).must_be_nil
    end
  end

  describe "forget" do
    it "drops the entry and the row without waiting for the prune window" do
      store = Store.new(path: nil, clock: -> { now })
      store.update([session(id: "a"), session(id: "b")])
      store.toggle_pin("a")

      store.forget("a")
      _(store.entry("a")).must_be_nil
      _(store.sections.all.map(&:id)).must_equal %w[b]
    end

    it "leaves an unknown id alone" do
      store = Store.new(path: nil, clock: -> { now })
      store.update([session(id: "a")])
      store.forget("nope")
      _(store.sections.all.map(&:id)).must_equal %w[a]
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
