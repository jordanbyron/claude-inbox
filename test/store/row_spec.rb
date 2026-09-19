# frozen_string_literal: true

require_relative "../test_helper"

Store = ClaudeInbox::Store unless defined?(Store)

describe ClaudeInbox::Store::Row do
  let(:now) { Time.at(1_789_600_000) }

  def row(s, entry) = Store::Row.new(session: s, entry: entry && Store::Entry.new(entry))

  it "shows the alias over the session's name, and searches label or cwd" do
    plain = row(session(id: "a", name: "Thing", cwd: "/srv/Other"), nil)
    _(plain.label).must_equal "Thing"
    _(plain.alias_name).must_be_nil
    _(plain.matches?("thing")).must_equal true
    _(plain.matches?("other")).must_equal true
    _(plain.matches?("zzz")).must_equal false

    aliased = row(session(id: "a", name: "Thing"), {"alias" => "flaky"})
    _(aliased.label).must_equal "flaky"
    _(aliased.matches?("flaky")).must_equal true
    _(aliased.matches?("thing")).must_equal false
  end

  it "answers nil for every reader when no poll has recorded the session yet" do
    r = row(session(id: "a"), nil)
    _(r.entry).must_be_nil
    _(r.wake_at).must_be_nil
    _(r.state_since).must_be_nil
    _(r.pinned_at).must_be_nil
    _(r.pinned?).must_be_nil
    _(r.parked?).must_be_nil
    _(r.reap_failed_at).must_be_nil
    _(r.section(now)).must_equal :active
  end

  it "is selectable only with a key" do
    _(row(session(id: "a"), nil)).must_be :selectable?
    _(row(session(id: nil, session_id: nil, kind: "interactive"), nil)).wont_be :selectable?
  end

  it "reads the entry through its accessors" do
    r = row(session(id: "a"), {"wake_at" => Store::UNTIL_WOKEN, "state_since" => 5, "pinned" => true, "pinned_at" => 6, "reap_failed_at" => 7})
    _(r.wake_at).must_equal Store::UNTIL_WOKEN
    _(r.parked?).must_equal true
    _(r.state_since).must_equal 5
    _(r.pinned?).must_equal true
    _(r.pinned_at).must_equal 6
    _(r.reap_failed_at).must_equal 7
  end

  describe "reap rule" do
    def reapable?(s, entry) = row(s, entry).reapable?(now.to_i)

    def draft_pr = ClaudeInbox::PullRequest.new(number: 1, url: "https://github.com/o/r/pull/1", state: "DRAFT")

    let(:quiet) { {"last_state" => "done", "state_since" => now.to_i - Store::REAP_AFTER - 1} }
    let(:recent) { {"last_state" => "done", "state_since" => now.to_i - Store::REAP_AFTER + 60} }

    it "reaps a finished session quiet for longer than REAP_AFTER" do
      _(reapable?(session(id: "a", state: "done"), quiet)).must_equal true
    end

    it "leaves one that has been quiet for less" do
      _(reapable?(session(id: "a", state: "done"), recent)).must_equal false
    end

    it "reaps on idle time alone, where settling waits on the pull request" do
      s = session(id: "a", state: "done", prs: [draft_pr])
      _(row(s, quiet).settled?).must_equal false
      _(reapable?(s, quiet)).must_equal true
    end

    it "reaps a long-dead failure, which never settles" do
      s = session(id: "a", state: "failed")
      _(row(s, quiet).settled?).must_equal false
      _(reapable?(s, quiet)).must_equal true
    end

    it "never reaps a working session" do
      _(reapable?(session(id: "a", state: "working"), quiet)).must_equal false
    end

    it "never reaps one that still has a process" do
      _(reapable?(session(id: "a", state: "done", pid: 4321), quiet)).must_equal false
    end

    it "never reaps a pin or a snooze, however long it has been parked" do
      _(reapable?(session(id: "a", state: "done"), quiet.merge("pinned" => true))).must_equal false
      _(reapable?(session(id: "a", state: "done"), quiet.merge("wake_at" => Store::UNTIL_WOKEN, "snoozed_at" => 1))).must_equal false
    end

    it "reaps once an elapsed snooze has woken it" do
      woken = quiet.merge("wake_at" => now.to_i - 60, "snoozed_at" => now.to_i - 120)
      _(reapable?(session(id: "a", state: "done"), woken)).must_equal true
    end

    it "never reaps a session there is no id to reap with" do
      s = session(id: nil, kind: "interactive", state: nil, status: "idle", session_id: "u9")
      _(reapable?(s, quiet)).must_equal false
    end

    it "never reaps a session it has no entry for" do
      _(reapable?(session(id: "a", state: "done"), nil)).must_equal false
    end
  end
end
