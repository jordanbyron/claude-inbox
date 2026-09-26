# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeInbox::Store, :store do
  let(:now) { Time.at(1_789_600_000) }

  describe "sectioning" do
    it "puts blocked and failed in Needs you" do
      sec = sections([session(id: "a", state: "blocked"), session(id: "b", state: "failed"), session(id: "c")])
      expect(ids(sec.needs_you).sort).to eq(%w[a b])
      expect(ids(sec.active)).to eq(%w[c])
    end

    it "shows a busy terminal in Active, selectable but not actionable" do
      sec = sections([session(id: nil, kind: "interactive", state: nil, status: "busy", session_id: "uuid")])
      expect(sec.active.size).to eq(1)
      expect(sec.active.first).to be_selectable
      expect(sec.active.first.session).not_to be_actionable
      expect(sec.active.first.session.effective_state).to eq("working")
    end

    it "settles an idle remote session with a resolved PR, and lets it snooze" do
      r = session(id: nil, kind: "interactive", state: nil, status: "idle", session_id: "u9", origin: :remote, started_at: now - 3600, prs: [pr("MERGED")])
      entries = {"u9" => {"last_state" => "done", "state_since" => now.to_i - 5}}
      expect(sections([r], entries).settled.map(&:key)).to eq(%w[u9])
      snoozed = {"u9" => {"wake_at" => now.to_i + 900, "last_state" => "done", "state_since" => now.to_i - 3600}}
      expect(sections([r], snoozed).snoozed.map(&:key)).to eq(%w[u9])
    end

    it "tracks remote sessions in merge_entries by session uuid" do
      r = session(id: nil, kind: "interactive", state: nil, status: "busy", session_id: "u9", origin: :remote)
      e = described_class.merge_entries({}, [r], now)
      expect(e["u9"]["last_state"]).to eq("working")
      e = described_class.merge_entries(e, [r.with(status: "idle")], now + 60)
      expect(e["u9"]["last_state"]).to eq("done")
      expect(e["u9"]["state_since"]).to eq((now + 60).to_i)
    end

    it "never settles or snoozes a terminal, even when idle for ages" do
      s = session(id: nil, kind: "interactive", state: nil, status: "idle", session_id: "uuid", started_at: now - 86_400)
      sec = sections([s], {}, now)
      expect(sec.active.map(&:key)).to eq(%w[uuid])
      expect(sec.settled).to be_empty
    end

    it "keeps a freshly finished session in Active" do
      entries = {"a" => {"last_state" => "done", "state_since" => now.to_i - 60}}
      sec = sections([session(id: "a", state: "done")], entries)
      expect(ids(sec.active)).to eq(%w[a])
      expect(sec.settled).to be_empty
    end

    it "never settles a finished session with no pull request, however long it has been quiet" do
      entries = {"a" => {"last_state" => "done", "state_since" => now.to_i - 86_400}}
      sec = sections([session(id: "a", state: "done")], entries)
      expect(ids(sec.active)).to eq(%w[a])
      expect(sec.settled).to be_empty
    end

    it "keeps a finished session up while its PR is open, however long it has been quiet" do
      entries = {"a" => {"last_state" => "done", "state_since" => now.to_i - 86_400}}
      %w[OPEN DRAFT].each do |st|
        sec = sections([session(id: "a", state: "done", prs: [pr(st)])], entries)
        expect(ids(sec.active)).to eq(%w[a])
      end
    end

    it "settles a finished session the moment its PR is merged or closed" do
      entries = {"a" => {"last_state" => "done", "state_since" => now.to_i - 5}}
      %w[MERGED CLOSED].each do |st|
        sec = sections([session(id: "a", state: "done", prs: [pr(st)])], entries)
        expect(ids(sec.settled)).to eq(%w[a])
      end
    end

    it "waits for every known PR, and never settles on an unknown PR state" do
      entries = {"a" => {"last_state" => "done", "state_since" => now.to_i - 5}}
      expect(ids(sections([session(id: "a", state: "done", prs: [pr("MERGED"), pr("OPEN")])], entries).active)).to eq(%w[a])
      expect(ids(sections([session(id: "a", state: "done", prs: [pr(nil)])], entries).active)).to eq(%w[a])
      expect(ids(sections([session(id: "a", state: "working", prs: [pr("MERGED")])], entries).active)).to eq(%w[a])
    end

    # A session that opens a PR ends its turn `blocked` on "anything need
    # changing before I flip it to ready?", never `done`. Merging answers it.
    it "settles a blocked session the moment its PR is merged or closed" do
      entries = {"a" => {"last_state" => "blocked", "state_since" => now.to_i - 5}}
      %w[MERGED CLOSED].each do |st|
        sec = sections([session(id: "a", state: "blocked", prs: [pr(st)])], entries)
        expect(ids(sec.settled)).to eq(%w[a])
        expect(sec.needs_you).to be_empty
      end
    end

    it "keeps a blocked session in Needs you while its PR is still open" do
      entries = {"a" => {"last_state" => "blocked", "state_since" => now.to_i - 86_400}}
      %w[OPEN DRAFT].each do |st|
        expect(ids(sections([session(id: "a", state: "blocked", prs: [pr(st)])], entries).needs_you)).to eq(%w[a])
      end
    end

    it "settles a merged blocked session you had already attached to" do
      entries = {"a" => {"last_state" => "blocked", "state_since" => now.to_i - 30, "acknowledged_at" => now.to_i - 10}}
      sec = sections([session(id: "a", state: "blocked", prs: [pr("MERGED")])], entries)
      expect(ids(sec.settled)).to eq(%w[a])
      expect(sec.active).to be_empty
    end

    it "keeps a failed session loud even once its PR merged" do
      entries = {"a" => {"last_state" => "failed", "state_since" => now.to_i - 5}}
      sec = sections([session(id: "a", state: "failed", prs: [pr("MERGED")])], entries)
      expect(ids(sec.needs_you)).to eq(%w[a])
      expect(sec.settled).to be_empty
    end
  end

  describe "pinning" do
    it "parks a pinned session at the top regardless of state" do
      entries = {"a" => {"pinned" => true, "pinned_at" => now.to_i, "last_state" => "working"}}
      sec = sections([session(id: "a")], entries)
      expect(ids(sec.pinned)).to eq(%w[a])
      expect(sec.active).to be_empty
    end

    it "overrides needs_you, snoozed and settled" do
      entries = {"a" => {"pinned" => true, "pinned_at" => now.to_i, "last_state" => "blocked"}}
      expect(ids(sections([session(id: "a", state: "blocked")], entries).pinned)).to eq(%w[a])

      entries = {"a" => {"pinned" => true, "pinned_at" => now.to_i, "wake_at" => now.to_i + 900, "last_state" => "working"}}
      expect(ids(sections([session(id: "a")], entries).pinned)).to eq(%w[a])

      entries = {"a" => {"pinned" => true, "pinned_at" => now.to_i, "settled_at" => now.to_i, "last_state" => "done", "state_since" => now.to_i - 60}}
      expect(ids(sections([session(id: "a", state: "done")], entries).pinned)).to eq(%w[a])
    end

    it "sorts Pinned with the most recently pinned first" do
      entries = {"a" => {"pinned" => true, "pinned_at" => now.to_i - 60}, "b" => {"pinned" => true, "pinned_at" => now.to_i}}
      expect(ids(sections(%w[a b].map { |i| session(id: i) }, entries).pinned)).to eq(%w[b a])
    end

    it "toggle_pin sets and clears pinned via the store" do
      clock = -> { now }
      Dir.mktmpdir do |dir|
        store = described_class.new(path: File.join(dir, "state.json"), clock: clock)
        store.update([session(id: "a")])
        store.toggle_pin("a")
        expect(store.sections.pinned.map(&:id)).to eq(%w[a])
        store.toggle_pin("a")
        expect(store.sections.pinned).to be_empty
      end
    end
  end

  describe "settle rule" do
    it "settles a done session by hand" do
      entries = {"a" => {"settled_at" => now.to_i, "last_state" => "done", "state_since" => now.to_i - 60}}
      expect(ids(sections([session(id: "a", state: "done")], entries).settled)).to eq(%w[a])
    end

    it "settles a stopped session with a resolved PR" do
      entries = {"a" => {"last_state" => "stopped", "state_since" => now.to_i - 3600}}
      expect(ids(sections([session(id: "a", state: "stopped", prs: [pr("MERGED")])], entries).settled)).to eq(%w[a])
    end

    it "never settles failed" do
      entries = {"a" => {"last_state" => "failed", "state_since" => now.to_i - 86_400 * 3}}
      sec = sections([session(id: "a", state: "failed")], entries)
      expect(sec.settled).to be_empty
      expect(ids(sec.needs_you)).to eq(%w[a])
    end

    it "seeds state_since from started_at for a first-seen finished session whose process was reaped" do
      s = session(id: "a", state: "done", pid: nil, started_at: now - 86_400)
      entries = described_class.merge_entries({}, [s], now)
      expect(entries["a"]["state_since"]).to eq((now - 86_400).to_i)
    end

    it "seeds state_since from now for a first-seen finished session that is still alive" do
      s = session(id: "a", state: "done", pid: 123, status: "idle")
      entries = described_class.merge_entries({}, [s], now)
      expect(entries["a"]["state_since"]).to eq(now.to_i)
    end
  end

  describe "snooze and wake" do
    it "hides a snoozed session in Snoozed" do
      entries = {"a" => {"wake_at" => now.to_i + 900, "last_state" => "working"}}
      sec = sections([session(id: "a")], entries)
      expect(ids(sec.snoozed)).to eq(%w[a])
      expect(sec.active).to be_empty
    end

    it "wakes when the session becomes blocked after the snooze" do
      entries = {"a" => {"wake_at" => now.to_i + 900, "snoozed_at" => now.to_i - 300, "last_state" => "working", "state_since" => now.to_i - 400}}
      entries = described_class.merge_entries(entries, [session(id: "a", state: "blocked")], now)
      sec = sections([session(id: "a", state: "blocked")], entries)
      expect(ids(sec.needs_you)).to eq(%w[a])
      expect(sec.snoozed).to be_empty
      expect(entries["a"]).not_to include("wake_at")
    end

    it "wakes a parked session when it fails" do
      entries = {"a" => {"wake_at" => described_class::UNTIL_WOKEN, "snoozed_at" => now.to_i - 300, "last_state" => "working", "state_since" => now.to_i - 400}}
      entries = described_class.merge_entries(entries, [session(id: "a", state: "failed")], now)
      expect(ids(sections([session(id: "a", state: "failed")], entries).needs_you)).to eq(%w[a])
    end

    it "keeps an already-blocked session snoozed" do
      entries = described_class.merge_entries({"a" => {"last_state" => "blocked", "state_since" => now.to_i - 600}}, [session(id: "a", state: "blocked")], now)
      snoozed = entries.merge("a" => entries["a"].merge("wake_at" => now.to_i + 900, "snoozed_at" => now.to_i))
      later = described_class.merge_entries(snoozed, [session(id: "a", state: "blocked")], now + 60)
      sec = sections([session(id: "a", state: "blocked")], later, now + 60)
      expect(ids(sec.snoozed)).to eq(%w[a])
      expect(sec.needs_you).to be_empty
    end

    it "wakes when wake_at has elapsed" do
      entries = {"a" => {"wake_at" => now.to_i - 1, "last_state" => "working"}}
      expect(ids(sections([session(id: "a")], entries).active)).to eq(%w[a])
    end

    it "never wakes until_woken on its own" do
      entries = {"a" => {"wake_at" => described_class::UNTIL_WOKEN, "last_state" => "working"}}
      sec = sections([session(id: "a")], entries, now + 86_400 * 30)
      expect(ids(sec.snoozed)).to eq(%w[a])
      expect(sec.snoozed.first).to be_parked
    end

    it "sorts Snoozed by wake_at with parked last" do
      entries = {"a" => {"wake_at" => described_class::UNTIL_WOKEN}, "b" => {"wake_at" => now.to_i + 3600}, "c" => {"wake_at" => now.to_i + 60}}
      expect(ids(sections(%w[a b c].map { |i| session(id: i) }, entries).snoozed)).to eq(%w[c b a])
    end

    it "lets snooze win over settle even with a resolved PR" do
      entries = {"a" => {"wake_at" => now.to_i + 900, "last_state" => "done", "state_since" => now.to_i - 3600}}
      expect(ids(sections([session(id: "a", state: "done", prs: [pr("MERGED")])], entries).snoozed)).to eq(%w[a])
    end
  end

  describe "hand settle" do
    it "settles a working session at once" do
      entries = {"a" => {"settled_at" => now.to_i, "last_state" => "working", "state_since" => now.to_i - 60}}
      expect(ids(sections([session(id: "a")], entries).settled)).to eq(%w[a])
    end

    it "settles a blocked session and keeps it settled while still blocked" do
      entries = {"a" => {"settled_at" => now.to_i, "last_state" => "blocked", "state_since" => now.to_i - 60}}
      sec = sections([session(id: "a", state: "blocked")], entries, now + 3600)
      expect(ids(sec.settled)).to eq(%w[a])
      expect(sec.needs_you).to be_empty
    end

    it "stays settled when the session finishes" do
      entries = {"a" => {"settled_at" => now.to_i, "last_state" => "working", "state_since" => now.to_i - 60}}
      later = described_class.merge_entries(entries, [session(id: "a", state: "done")], now + 30)
      expect(later["a"]["settled_at"]).to eq(now.to_i)
      expect(ids(sections([session(id: "a", state: "done")], later, now + 30).settled)).to eq(%w[a])
    end

    it "comes back when the session starts working again" do
      entries = {"a" => {"settled_at" => now.to_i, "last_state" => "blocked", "state_since" => now.to_i - 60}}
      later = described_class.merge_entries(entries, [session(id: "a", state: "working")], now + 30)
      expect(later["a"]).not_to include("settled_at")
      expect(ids(sections([session(id: "a", state: "working")], later, now + 30).active)).to eq(%w[a])
    end

    it "comes back when the session becomes blocked afterwards" do
      entries = {"a" => {"settled_at" => now.to_i, "last_state" => "working", "state_since" => now.to_i - 60}}
      later = described_class.merge_entries(entries, [session(id: "a", state: "blocked")], now + 30)
      expect(later["a"]).not_to include("settled_at")
      expect(ids(sections([session(id: "a", state: "blocked")], later, now + 30).needs_you)).to eq(%w[a])
    end

    it "is lifted by wake and replaces a snooze" do
      Dir.mktmpdir do |dir|
        store = described_class.new(path: File.join(dir, "state.json"), clock: -> { now })
        store.snooze("a", :h1)
        store.settle("a")
        expect(store.entry("a")).not_to include("wake_at")
        expect(store.entry("a")["settled_at"]).to eq(now.to_i)
        store.wake("a")
        expect(store.entry("a")).not_to include("settled_at")
      end
    end

    it "takes hold again after a wake, even with no state change in between" do
      Dir.mktmpdir do |dir|
        store = described_class.new(path: File.join(dir, "state.json"), clock: -> { now })
        store.update([session(id: "a", state: "blocked")])
        store.wake("a")
        store.settle("a")
        expect(store.sections.settled.map(&:id)).to eq(%w[a])
      end
    end
  end

  describe "revive rule" do
    it "brings back a session settled by a resolved PR" do
      entries = {"a" => {"last_state" => "done", "state_since" => now.to_i - 5, "revived_at" => now.to_i}}
      sec = sections([session(id: "a", state: "done", prs: [pr("MERGED")])], entries)
      expect(ids(sec.active)).to eq(%w[a])
      expect(sec.settled).to be_empty
    end

    it "brings back a hand-settled session that would otherwise stay settled" do
      entries = {"a" => {"settled_at" => now.to_i, "last_state" => "done", "state_since" => now.to_i - 60, "revived_at" => now.to_i + 1}}
      sec = sections([session(id: "a", state: "done")], entries)
      expect(ids(sec.active)).to eq(%w[a])
      expect(sec.settled).to be_empty
    end

    it "routes a revived needs-you session to Needs You, not Active" do
      entries = {"a" => {"settled_at" => now.to_i, "last_state" => "blocked", "state_since" => now.to_i - 60, "revived_at" => now.to_i + 1}}
      sec = sections([session(id: "a", state: "blocked")], entries)
      expect(ids(sec.needs_you)).to eq(%w[a])
    end

    it "clears once the state actually changes again" do
      entries = {"a" => {"last_state" => "blocked", "state_since" => now.to_i - 60, "revived_at" => now.to_i}}
      later = described_class.merge_entries(entries, [session(id: "a", state: "working")], now + 30)
      expect(later["a"]).not_to include("revived_at")
    end

    it "wake un-settles a resolved-PR session via the store" do
      Dir.mktmpdir do |dir|
        store = described_class.new(path: File.join(dir, "state.json"), clock: -> { now })
        store.update([session(id: "a", state: "done", prs: [pr("MERGED")])])
        expect(store.sections.settled.map(&:id)).to eq(%w[a])
        store.wake("a")
        expect(store.sections.active.map(&:id)).to eq(%w[a])
      end
    end
  end

  describe "acknowledge rule" do
    it "moves an acknowledged blocked session to Active, not Settled" do
      entries = {"a" => {"acknowledged_at" => now.to_i, "last_state" => "blocked", "state_since" => now.to_i - 60}}
      sec = sections([session(id: "a", state: "blocked")], entries)
      expect(ids(sec.active)).to eq(%w[a])
      expect(sec.needs_you).to be_empty
      expect(sec.settled).to be_empty
    end

    it "comes back to Needs You once the state changes again after acknowledging" do
      entries = {"a" => {"acknowledged_at" => now.to_i, "last_state" => "blocked", "state_since" => now.to_i - 60}}
      later = described_class.merge_entries(entries, [session(id: "a", state: "working")], now + 30)
      later = described_class.merge_entries(later, [session(id: "a", state: "blocked")], now + 60)
      expect(later["a"]).not_to include("acknowledged_at")
      expect(ids(sections([session(id: "a", state: "blocked")], later, now + 60).needs_you)).to eq(%w[a])
    end

    it "acknowledge sets acknowledged_at via the store" do
      Dir.mktmpdir do |dir|
        store = described_class.new(path: File.join(dir, "state.json"), clock: -> { now })
        store.update([session(id: "a", state: "blocked")])
        store.acknowledge("a")
        expect(store.entry("a")["acknowledged_at"]).to eq(now.to_i)
        expect(store.sections.active.map(&:id)).to eq(%w[a])
      end
    end
  end

  describe ".merge_entries" do
    it "bumps state_since only when state changes" do
      e = described_class.merge_entries({}, [session(id: "a")], now)
      expect(e["a"]["state_since"]).to eq(now.to_i)
      e = described_class.merge_entries(e, [session(id: "a")], now + 100)
      expect(e["a"]["state_since"]).to eq(now.to_i)
      e = described_class.merge_entries(e, [session(id: "a", state: "done")], now + 200)
      expect(e["a"]["state_since"]).to eq((now + 200).to_i)
      expect(e["a"]["last_state"]).to eq("done")
    end

    it "clears an elapsed snooze" do
      entries = {"a" => {"wake_at" => now.to_i - 1, "snoozed_at" => now.to_i - 901, "last_state" => "working"}}
      e = described_class.merge_entries(entries, [session(id: "a")], now)
      expect(e["a"]).not_to include("wake_at")
      expect(e["a"]).not_to include("snoozed_at")
    end

    it "keeps aliases and prunes stale entries" do
      entries = {
        "old" => {"alias" => "x", "last_seen" => now.to_i - described_class::PRUNE_AFTER - 1},
        "kept" => {"alias" => "y", "last_seen" => now.to_i - 100}
      }
      e = described_class.merge_entries(entries, [], now)
      expect(e).not_to include("old")
      expect(e["kept"]["alias"]).to eq("y")
    end

    it "skips rows with no key at all" do
      expect(described_class.merge_entries({}, [session(id: nil, session_id: nil, kind: "interactive")], now)).to be_empty
    end
  end

  describe ".folded?" do
    it "folds a foldable section until it is expanded" do
      expect(described_class.folded?(:settled, {})).to be(true)
      expect(described_class.folded?(:settled, {settled: true})).to be(false)
      expect(described_class.folded?(:active, {})).to be(false)
    end
  end

  describe "fixture end to end" do
    it "sections the captured sessions" do
      sessions = fixture_sessions
      at = Time.at(1_789_604_500)
      sec = described_class.sectionize(sessions, described_class.merge_entries({}, sessions, at), at)
      expect(ids(sec.needs_you)).to eq(%w[f23c8673])
      expect(ids(sec.active)).to eq([nil, "823b882f", "dcbc1d98", "b0b18338", "fbf5253a", "b03695b1"])
      expect(sec.settled).to be_empty
    end
  end

  describe "alias and pull request overrides" do
    let(:store) { described_class.new(path: nil, clock: -> { now }).tap { |st| st.update([session(id: "a")]) } }

    it "reads back what set_alias and set_pr wrote, and nil once cleared" do
      expect(store.alias_for("a")).to be_nil
      expect(store.pr_for("a")).to be_nil

      store.set_alias("a", "flaky test fix")
      store.set_pr("a", "https://github.com/o/r/pull/7")
      expect(store.alias_for("a")).to eq("flaky test fix")
      expect(store.pr_for("a")).to eq("https://github.com/o/r/pull/7")

      store.set_alias("a", "")
      store.set_pr("a", "")
      expect(store.alias_for("a")).to be_nil
      expect(store.pr_for("a")).to be_nil
    end

    it "answers nil for a session it has never seen" do
      expect(store.alias_for("nope")).to be_nil
      expect(store.pr_for("nope")).to be_nil
    end
  end

  describe "row" do
    it "pairs a session with its entry, and carries the last refused reap" do
      store = described_class.new(path: nil, clock: -> { now })
      s = session(id: "a")
      store.update([s])

      expect(store.row(s).reap_failed_at).to be_nil
      store.mark_reap_failed("a", "rm failed: worktree has unpushed commits\nmore")
      row = store.row(s)
      expect(row.session).to eq(s)
      expect(row.reap_failed_at).to eq(now.to_i)
      expect(row.state_since).to eq(now.to_i)
    end

    it "has no entry for a session with nothing to key on" do
      store = described_class.new(path: nil, clock: -> { now })
      row = store.row(session(id: nil, session_id: nil, kind: "interactive"))
      expect(row.entry).to be_nil
      expect(row.reap_failed_at).to be_nil
    end
  end

  describe "forget" do
    it "drops the entry and the row without waiting for the prune window" do
      store = described_class.new(path: nil, clock: -> { now })
      store.update([session(id: "a"), session(id: "b")])
      store.toggle_pin("a")

      store.forget("a")
      expect(store.entry("a")).to be_nil
      expect(store.sections.all.map(&:id)).to eq(%w[b])
    end

    it "leaves an unknown id alone" do
      store = described_class.new(path: nil, clock: -> { now })
      store.update([session(id: "a")])
      store.forget("nope")
      expect(store.sections.all.map(&:id)).to eq(%w[a])
    end

    it "keeps the session hidden while the daemon still lists it" do
      store = described_class.new(path: nil, clock: -> { now })
      store.update([session(id: "a"), session(id: "b")])
      store.forget("a")

      store.update([session(id: "a"), session(id: "b")])
      expect(store.sessions.map(&:id)).to eq(%w[b])
      expect(store.sections.all.map(&:id)).to eq(%w[b])
      expect(store.entry("a")).to be_nil
    end

    it "shows the key again once a poll without it has gone by" do
      store = described_class.new(path: nil, clock: -> { now })
      store.update([session(id: "a")])
      store.forget("a")
      store.update([session(id: "a")])
      store.update([])

      store.update([session(id: "a")])
      expect(store.sessions.map(&:id)).to eq(%w[a])
      expect(store.sections.all.map(&:id)).to eq(%w[a])
      expect(store.entry("a")).not_to be_nil
    end
  end

  describe "persistence" do
    it "round-trips through the file atomically" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "nested", "state.json")
        clock = -> { Time.at(1_789_600_000) }
        store = described_class.new(path: path, clock: clock)
        store.update([session(id: "a")])
        store.snooze("a", :h1)
        store.set_alias("a", "flaky test fix")

        data = JSON.parse(File.read(path))
        expect(data["version"]).to eq(1)
        expect(data["sessions"]["a"]["wake_at"]).to eq(1_789_603_600)
        expect(data["sessions"]["a"]["alias"]).to eq("flaky test fix")
        expect(Dir.glob(File.join(dir, "nested", ".state.*.tmp"))).to be_empty

        reloaded = described_class.new(path: path, clock: clock)
        reloaded.update([session(id: "a")])
        expect(reloaded.sections.snoozed.map(&:id)).to eq(%w[a])
        reloaded.wake("a")
        expect(reloaded.sections.snoozed).to be_empty
      end
    end
  end
end
