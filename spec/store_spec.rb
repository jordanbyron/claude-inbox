# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeInbox::Store do
  subject(:sec) { described_class.sectionize(sessions, entries, at) }

  let(:now) { Time.at(1_789_600_000) }
  let(:at) { now }
  let(:entries) { {} }
  let(:state) { "working" }
  let(:pr_states) { [] }
  let(:prs) { pr_states.map { |st| ClaudeInbox::PullRequest.new(number: 1, url: "https://github.com/o/r/pull/1", state: st) } }
  let(:sessions) { [session(id: "a", state: state, prs: prs)] }

  let(:path) { nil }
  let(:store) { described_class.new(path: path, clock: -> { now }) }

  shared_context "with a state file" do
    let(:dir) { Dir.mktmpdir }
    let(:path) { File.join(dir, "state.json") }

    after { FileUtils.remove_entry(dir) }
  end

  describe "sectioning" do
    context "with one blocked, one failed and one working session" do
      let(:sessions) { [session(id: "a", state: "blocked"), session(id: "b", state: "failed"), session(id: "c")] }

      it "puts blocked and failed in Needs you" do
        expect(sec.needs_you.map(&:id).sort).to eq(%w[a b])
        expect(sec.active.map(&:id)).to eq(%w[c])
      end
    end

    context "with a busy terminal" do
      let(:sessions) { [session(id: nil, kind: "interactive", state: nil, status: "busy", session_id: "uuid")] }

      it "shows a busy terminal in Active, selectable but not actionable" do
        expect(sec.active.size).to eq(1)
        expect(sec.active.first).to be_selectable
        expect(sec.active.first.session).not_to be_actionable
        expect(sec.active.first.session.effective_state).to eq("working")
      end
    end

    context "with an idle remote session whose PR merged" do
      let(:pr_states) { %w[MERGED] }
      let(:sessions) do
        [session(id: nil, kind: "interactive", state: nil, status: "idle", session_id: "u9", origin: :remote, started_at: now - 3600, prs: prs)]
      end

      context "that finished moments ago" do
        let(:entries) { {"u9" => {"last_state" => "done", "state_since" => now.to_i - 5}} }

        it "settles an idle remote session with a resolved PR" do
          expect(sec.settled.map(&:key)).to eq(%w[u9])
        end
      end

      context "that is snoozed" do
        let(:entries) { {"u9" => {"wake_at" => now.to_i + 900, "last_state" => "done", "state_since" => now.to_i - 3600}} }

        it "lets it snooze" do
          expect(sec.snoozed.map(&:key)).to eq(%w[u9])
        end
      end
    end

    it "tracks remote sessions in merge_entries by session uuid" do
      r = session(id: nil, kind: "interactive", state: nil, status: "busy", session_id: "u9", origin: :remote)
      e = described_class.merge_entries({}, [r], now)
      expect(e["u9"]["last_state"]).to eq("working")
      e = described_class.merge_entries(e, [r.with(status: "idle")], now + 60)
      expect(e["u9"]["last_state"]).to eq("done")
      expect(e["u9"]["state_since"]).to eq((now + 60).to_i)
    end

    context "with a terminal idle for a day" do
      let(:sessions) { [session(id: nil, kind: "interactive", state: nil, status: "idle", session_id: "uuid", started_at: now - 86_400)] }

      it "never settles or snoozes a terminal, even when idle for ages" do
        expect(sec.active.map(&:key)).to eq(%w[uuid])
        expect(sec.settled).to be_empty
      end
    end

    context "with a finished session" do
      let(:state) { "done" }

      context "a minute ago" do
        let(:entries) { {"a" => {"last_state" => "done", "state_since" => now.to_i - 60}} }

        it "keeps a freshly finished session in Active" do
          expect(sec.active.map(&:id)).to eq(%w[a])
          expect(sec.settled).to be_empty
        end
      end

      context "a day ago" do
        let(:entries) { {"a" => {"last_state" => "done", "state_since" => now.to_i - 86_400}} }

        it "never settles a finished session with no pull request, however long it has been quiet" do
          expect(sec.active.map(&:id)).to eq(%w[a])
          expect(sec.settled).to be_empty
        end

        %w[OPEN DRAFT].each do |st|
          context "with a #{st} PR" do
            let(:pr_states) { [st] }

            it "keeps a finished session up while its PR is open, however long it has been quiet" do
              expect(sec.active.map(&:id)).to eq(%w[a])
            end
          end
        end
      end

      context "moments ago" do
        let(:entries) { {"a" => {"last_state" => "done", "state_since" => now.to_i - 5}} }

        %w[MERGED CLOSED].each do |st|
          context "with a #{st} PR" do
            let(:pr_states) { [st] }

            it "settles a finished session the moment its PR is merged or closed" do
              expect(sec.settled.map(&:id)).to eq(%w[a])
            end
          end
        end

        context "with one PR merged and one open" do
          let(:pr_states) { %w[MERGED OPEN] }

          it "waits for every known PR" do
            expect(sec.active.map(&:id)).to eq(%w[a])
          end
        end

        context "with a PR in an unknown state" do
          let(:pr_states) { [nil] }

          it "never settles on an unknown PR state" do
            expect(sec.active.map(&:id)).to eq(%w[a])
          end
        end

        context "that is working again with its PR merged" do
          let(:state) { "working" }
          let(:pr_states) { %w[MERGED] }

          it "waits for the session to finish" do
            expect(sec.active.map(&:id)).to eq(%w[a])
          end
        end
      end
    end

    # A session that opens a PR ends its turn `blocked` on "anything need
    # changing before I flip it to ready?", never `done`. Merging answers it.
    context "with a blocked session" do
      let(:state) { "blocked" }

      context "moments ago" do
        let(:entries) { {"a" => {"last_state" => "blocked", "state_since" => now.to_i - 5}} }

        %w[MERGED CLOSED].each do |st|
          context "with a #{st} PR" do
            let(:pr_states) { [st] }

            it "settles a blocked session the moment its PR is merged or closed" do
              expect(sec.settled.map(&:id)).to eq(%w[a])
              expect(sec.needs_you).to be_empty
            end
          end
        end
      end

      context "a day ago" do
        let(:entries) { {"a" => {"last_state" => "blocked", "state_since" => now.to_i - 86_400}} }

        %w[OPEN DRAFT].each do |st|
          context "with a #{st} PR" do
            let(:pr_states) { [st] }

            it "keeps a blocked session in Needs you while its PR is still open" do
              expect(sec.needs_you.map(&:id)).to eq(%w[a])
            end
          end
        end
      end

      context "already attached to, with its PR merged" do
        let(:entries) { {"a" => {"last_state" => "blocked", "state_since" => now.to_i - 30, "acknowledged_at" => now.to_i - 10}} }
        let(:pr_states) { %w[MERGED] }

        it "settles a merged blocked session you had already attached to" do
          expect(sec.settled.map(&:id)).to eq(%w[a])
          expect(sec.active).to be_empty
        end
      end
    end

    context "with a failed session whose PR merged" do
      let(:state) { "failed" }
      let(:pr_states) { %w[MERGED] }
      let(:entries) { {"a" => {"last_state" => "failed", "state_since" => now.to_i - 5}} }

      it "keeps a failed session loud even once its PR merged" do
        expect(sec.needs_you.map(&:id)).to eq(%w[a])
        expect(sec.settled).to be_empty
      end
    end
  end

  describe "pinning" do
    context "with a working session pinned" do
      let(:entries) { {"a" => {"pinned" => true, "pinned_at" => now.to_i, "last_state" => "working"}} }

      it "parks a pinned session at the top regardless of state" do
        expect(sec.pinned.map(&:id)).to eq(%w[a])
        expect(sec.active).to be_empty
      end
    end

    context "with a blocked session pinned" do
      let(:state) { "blocked" }
      let(:entries) { {"a" => {"pinned" => true, "pinned_at" => now.to_i, "last_state" => "blocked"}} }

      it "overrides needs_you" do
        expect(sec.pinned.map(&:id)).to eq(%w[a])
      end
    end

    context "with a snoozed session pinned" do
      let(:entries) { {"a" => {"pinned" => true, "pinned_at" => now.to_i, "wake_at" => now.to_i + 900, "last_state" => "working"}} }

      it "overrides snoozed" do
        expect(sec.pinned.map(&:id)).to eq(%w[a])
      end
    end

    context "with a settled session pinned" do
      let(:state) { "done" }
      let(:entries) do
        {"a" => {"pinned" => true, "pinned_at" => now.to_i, "settled_at" => now.to_i, "last_state" => "done", "state_since" => now.to_i - 60}}
      end

      it "overrides settled" do
        expect(sec.pinned.map(&:id)).to eq(%w[a])
      end
    end

    context "with two sessions pinned a minute apart" do
      let(:sessions) { %w[a b].map { |i| session(id: i) } }
      let(:entries) { {"a" => {"pinned" => true, "pinned_at" => now.to_i - 60}, "b" => {"pinned" => true, "pinned_at" => now.to_i}} }

      it "sorts Pinned with the most recently pinned first" do
        expect(sec.pinned.map(&:id)).to eq(%w[b a])
      end
    end

    context "through the store" do
      include_context "with a state file"

      before { store.update([session(id: "a")]) }

      it "toggle_pin sets and clears pinned via the store" do
        store.toggle_pin("a")
        expect(store.sections.pinned.map(&:id)).to eq(%w[a])
        store.toggle_pin("a")
        expect(store.sections.pinned).to be_empty
      end
    end
  end

  describe "settle rule" do
    context "with a done session settled by hand" do
      let(:state) { "done" }
      let(:entries) { {"a" => {"settled_at" => now.to_i, "last_state" => "done", "state_since" => now.to_i - 60}} }

      it "settles a done session by hand" do
        expect(sec.settled.map(&:id)).to eq(%w[a])
      end
    end

    context "with a stopped session whose PR merged" do
      let(:state) { "stopped" }
      let(:pr_states) { %w[MERGED] }
      let(:entries) { {"a" => {"last_state" => "stopped", "state_since" => now.to_i - 3600}} }

      it "settles a stopped session with a resolved PR" do
        expect(sec.settled.map(&:id)).to eq(%w[a])
      end
    end

    context "with a session failed for three days" do
      let(:state) { "failed" }
      let(:entries) { {"a" => {"last_state" => "failed", "state_since" => now.to_i - 86_400 * 3}} }

      it "never settles failed" do
        expect(sec.settled).to be_empty
        expect(sec.needs_you.map(&:id)).to eq(%w[a])
      end
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
    context "with a session snoozed for fifteen minutes" do
      let(:entries) { {"a" => {"wake_at" => now.to_i + 900, "last_state" => "working"}} }

      it "hides a snoozed session in Snoozed" do
        expect(sec.snoozed.map(&:id)).to eq(%w[a])
        expect(sec.active).to be_empty
      end
    end

    context "with a snoozed session that has since blocked" do
      let(:state) { "blocked" }
      let(:entries) do
        described_class.merge_entries(
          {"a" => {"wake_at" => now.to_i + 900, "snoozed_at" => now.to_i - 300, "last_state" => "working", "state_since" => now.to_i - 400}},
          sessions, now
        )
      end

      it "wakes when the session becomes blocked after the snooze" do
        expect(sec.needs_you.map(&:id)).to eq(%w[a])
        expect(sec.snoozed).to be_empty
        expect(entries["a"]).not_to include("wake_at")
      end
    end

    context "with a parked session that has since failed" do
      let(:state) { "failed" }
      let(:entries) do
        described_class.merge_entries(
          {"a" => {"wake_at" => described_class::UNTIL_WOKEN, "snoozed_at" => now.to_i - 300, "last_state" => "working", "state_since" => now.to_i - 400}},
          sessions, now
        )
      end

      it "wakes a parked session when it fails" do
        expect(sec.needs_you.map(&:id)).to eq(%w[a])
      end
    end

    context "with a session snoozed while already blocked" do
      let(:state) { "blocked" }
      let(:at) { now + 60 }
      let(:entries) do
        blocked = described_class.merge_entries({"a" => {"last_state" => "blocked", "state_since" => now.to_i - 600}}, sessions, now)
        snoozed = blocked.merge("a" => blocked["a"].merge("wake_at" => now.to_i + 900, "snoozed_at" => now.to_i))
        described_class.merge_entries(snoozed, sessions, at)
      end

      it "keeps an already-blocked session snoozed" do
        expect(sec.snoozed.map(&:id)).to eq(%w[a])
        expect(sec.needs_you).to be_empty
      end
    end

    context "with a snooze that has elapsed" do
      let(:entries) { {"a" => {"wake_at" => now.to_i - 1, "last_state" => "working"}} }

      it "wakes when wake_at has elapsed" do
        expect(sec.active.map(&:id)).to eq(%w[a])
      end
    end

    context "with a session parked until woken, a month on" do
      let(:at) { now + 86_400 * 30 }
      let(:entries) { {"a" => {"wake_at" => described_class::UNTIL_WOKEN, "last_state" => "working"}} }

      it "never wakes until_woken on its own" do
        expect(sec.snoozed.map(&:id)).to eq(%w[a])
        expect(sec.snoozed.first).to be_parked
      end
    end

    context "with three snoozed sessions" do
      let(:sessions) { %w[a b c].map { |i| session(id: i) } }
      let(:entries) { {"a" => {"wake_at" => described_class::UNTIL_WOKEN}, "b" => {"wake_at" => now.to_i + 3600}, "c" => {"wake_at" => now.to_i + 60}} }

      it "sorts Snoozed by wake_at with parked last" do
        expect(sec.snoozed.map(&:id)).to eq(%w[c b a])
      end
    end

    context "with a snoozed session whose PR merged" do
      let(:state) { "done" }
      let(:pr_states) { %w[MERGED] }
      let(:entries) { {"a" => {"wake_at" => now.to_i + 900, "last_state" => "done", "state_since" => now.to_i - 3600}} }

      it "lets snooze win over settle even with a resolved PR" do
        expect(sec.snoozed.map(&:id)).to eq(%w[a])
      end
    end
  end

  describe "hand settle" do
    let(:settled) { {"a" => {"settled_at" => now.to_i, "last_state" => last_state, "state_since" => now.to_i - 60}} }

    context "with a working session" do
      let(:last_state) { "working" }
      let(:entries) { settled }

      it "settles a working session at once" do
        expect(sec.settled.map(&:id)).to eq(%w[a])
      end
    end

    context "with a blocked session an hour on" do
      let(:last_state) { "blocked" }
      let(:state) { "blocked" }
      let(:entries) { settled }
      let(:at) { now + 3600 }

      it "settles a blocked session and keeps it settled while still blocked" do
        expect(sec.settled.map(&:id)).to eq(%w[a])
        expect(sec.needs_you).to be_empty
      end
    end

    context "when the state then moves" do
      let(:at) { now + 30 }
      let(:entries) { described_class.merge_entries(settled, sessions, at) }

      context "from working to done" do
        let(:last_state) { "working" }
        let(:state) { "done" }

        it "stays settled when the session finishes" do
          expect(entries["a"]["settled_at"]).to eq(now.to_i)
          expect(sec.settled.map(&:id)).to eq(%w[a])
        end
      end

      context "from blocked to working" do
        let(:last_state) { "blocked" }
        let(:state) { "working" }

        it "comes back when the session starts working again" do
          expect(entries["a"]).not_to include("settled_at")
          expect(sec.active.map(&:id)).to eq(%w[a])
        end
      end

      context "from working to blocked" do
        let(:last_state) { "working" }
        let(:state) { "blocked" }

        it "comes back when the session becomes blocked afterwards" do
          expect(entries["a"]).not_to include("settled_at")
          expect(sec.needs_you.map(&:id)).to eq(%w[a])
        end
      end
    end

    context "through the store" do
      include_context "with a state file"

      it "is lifted by wake and replaces a snooze" do
        store.snooze("a", :h1)
        store.settle("a")
        expect(store.entry("a")).not_to include("wake_at")
        expect(store.entry("a")["settled_at"]).to eq(now.to_i)
        store.wake("a")
        expect(store.entry("a")).not_to include("settled_at")
      end

      it "takes hold again after a wake, even with no state change in between" do
        store.update([session(id: "a", state: "blocked")])
        store.wake("a")
        store.settle("a")
        expect(store.sections.settled.map(&:id)).to eq(%w[a])
      end
    end
  end

  describe "revive rule" do
    context "with a session settled by a merged PR" do
      let(:state) { "done" }
      let(:pr_states) { %w[MERGED] }
      let(:entries) { {"a" => {"last_state" => "done", "state_since" => now.to_i - 5, "revived_at" => now.to_i}} }

      it "brings back a session settled by a resolved PR" do
        expect(sec.active.map(&:id)).to eq(%w[a])
        expect(sec.settled).to be_empty
      end
    end

    context "with a hand-settled done session" do
      let(:state) { "done" }
      let(:entries) { {"a" => {"settled_at" => now.to_i, "last_state" => "done", "state_since" => now.to_i - 60, "revived_at" => now.to_i + 1}} }

      it "brings back a hand-settled session that would otherwise stay settled" do
        expect(sec.active.map(&:id)).to eq(%w[a])
        expect(sec.settled).to be_empty
      end
    end

    context "with a hand-settled blocked session" do
      let(:state) { "blocked" }
      let(:entries) { {"a" => {"settled_at" => now.to_i, "last_state" => "blocked", "state_since" => now.to_i - 60, "revived_at" => now.to_i + 1}} }

      it "routes a revived needs-you session to Needs You, not Active" do
        expect(sec.needs_you.map(&:id)).to eq(%w[a])
      end
    end

    it "clears once the state actually changes again" do
      entries = {"a" => {"last_state" => "blocked", "state_since" => now.to_i - 60, "revived_at" => now.to_i}}
      later = described_class.merge_entries(entries, [session(id: "a", state: "working")], now + 30)
      expect(later["a"]).not_to include("revived_at")
    end

    context "through the store" do
      include_context "with a state file"

      let(:state) { "done" }
      let(:pr_states) { %w[MERGED] }

      before { store.update(sessions) }

      it "wake un-settles a resolved-PR session via the store" do
        expect(store.sections.settled.map(&:id)).to eq(%w[a])
        store.wake("a")
        expect(store.sections.active.map(&:id)).to eq(%w[a])
      end
    end
  end

  describe "acknowledge rule" do
    let(:state) { "blocked" }
    let(:acknowledged) { {"a" => {"acknowledged_at" => now.to_i, "last_state" => "blocked", "state_since" => now.to_i - 60}} }

    context "right after acknowledging" do
      let(:entries) { acknowledged }

      it "moves an acknowledged blocked session to Active, not Settled" do
        expect(sec.active.map(&:id)).to eq(%w[a])
        expect(sec.needs_you).to be_empty
        expect(sec.settled).to be_empty
      end
    end

    context "once it has worked and blocked again" do
      let(:at) { now + 60 }
      let(:entries) do
        working = described_class.merge_entries(acknowledged, [session(id: "a", state: "working")], now + 30)
        described_class.merge_entries(working, sessions, at)
      end

      it "comes back to Needs You once the state changes again after acknowledging" do
        expect(entries["a"]).not_to include("acknowledged_at")
        expect(sec.needs_you.map(&:id)).to eq(%w[a])
      end
    end

    context "through the store" do
      include_context "with a state file"

      before { store.update(sessions) }

      it "acknowledge sets acknowledged_at via the store" do
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
    let(:sessions) { fixture_sessions }
    let(:at) { Time.at(1_789_604_500) }
    let(:entries) { described_class.merge_entries({}, sessions, at) }

    it "sections the captured sessions" do
      expect(sec.needs_you.map(&:id)).to eq(%w[f23c8673])
      expect(sec.active.map(&:id)).to eq([nil, "823b882f", "dcbc1d98", "b0b18338", "fbf5253a", "b03695b1"])
      expect(sec.settled).to be_empty
    end
  end

  describe "alias and pull request overrides" do
    before { store.update([session(id: "a")]) }

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

  describe "#row" do
    it "pairs a session with its entry, and carries the last refused reap" do
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
      row = store.row(session(id: nil, session_id: nil, kind: "interactive"))
      expect(row.entry).to be_nil
      expect(row.reap_failed_at).to be_nil
    end
  end

  describe "#forget" do
    it "drops the entry and the row without waiting for the prune window" do
      store.update([session(id: "a"), session(id: "b")])
      store.toggle_pin("a")

      store.forget("a")
      expect(store.entry("a")).to be_nil
      expect(store.sections.all.map(&:id)).to eq(%w[b])
    end

    it "leaves an unknown id alone" do
      store.update([session(id: "a")])
      store.forget("nope")
      expect(store.sections.all.map(&:id)).to eq(%w[a])
    end

    it "keeps the session hidden while the daemon still lists it" do
      store.update([session(id: "a"), session(id: "b")])
      store.forget("a")

      store.update([session(id: "a"), session(id: "b")])
      expect(store.sessions.map(&:id)).to eq(%w[b])
      expect(store.sections.all.map(&:id)).to eq(%w[b])
      expect(store.entry("a")).to be_nil
    end

    it "shows the key again once a poll without it has gone by" do
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
    include_context "with a state file"

    let(:path) { File.join(dir, "nested", "state.json") }

    before do
      store.update([session(id: "a")])
      store.snooze("a", :h1)
      store.set_alias("a", "flaky test fix")
    end

    it "round-trips through the file atomically" do
      data = JSON.parse(File.read(path))
      expect(data["version"]).to eq(1)
      expect(data["sessions"]["a"]["wake_at"]).to eq(1_789_603_600)
      expect(data["sessions"]["a"]["alias"]).to eq("flaky test fix")
      expect(Dir.glob(File.join(dir, "nested", ".state.*.tmp"))).to be_empty

      reloaded = described_class.new(path: path, clock: -> { now })
      reloaded.update([session(id: "a")])
      expect(reloaded.sections.snoozed.map(&:id)).to eq(%w[a])
      reloaded.wake("a")
      expect(reloaded.sections.snoozed).to be_empty
    end
  end
end
