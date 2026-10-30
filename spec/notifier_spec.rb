# frozen_string_literal: true

RSpec.describe ClaudeInbox::Notifier do
  let(:clock) { StillClock.new(Time.at(1_789_604_500)) }
  let(:store) { ClaudeInbox::Store.new(path: nil, clock: clock) }
  let(:working) { session(state: "working") }
  let(:blocked) { session(state: "blocked", line: "Approve rm -rf tmp/?") }
  let(:done) { session(state: "done", line: "Opened #42.") }
  # The sections from before and after the store takes a poll, a few seconds on.
  let(:poll) do
    lambda do |*sessions|
      clock.advance(5)
      before = store.sections
      store.update(sessions)
      [before, store.sections]
    end
  end

  describe ".diff" do
    it "names a row that came to need you, with what it needs" do
      poll[working]
      notifications = described_class.diff(*poll[blocked])
      expect(notifications.map(&:to_h)).to eq([{key: "abc12345", kind: "needs you", label: "thing", line: "Approve rm -rf tmp/?"}])
      expect(notifications.first.message).to eq("🔴 needs you: Approve rm -rf tmp/?")
    end

    it "names a background session that finished, with its closing line" do
      poll[working]
      expect(described_class.diff(*poll[done]).map(&:message)).to eq(["finished: Opened #42."])
    end

    it "says only the kind when the session has no line" do
      poll[working]
      expect(described_class.diff(*poll[session(state: "error")]).map(&:message)).to eq(["🔴 needs you"])
    end

    it "says nothing for a row that already needed you, or one that was stopped" do
      poll[session(state: "error")]
      expect(described_class.diff(*poll[blocked])).to be_empty
      poll[working]
      expect(described_class.diff(*poll[session(state: "idle")])).to be_empty
    end

    it "keeps quiet about the terminal you are sitting in" do
      poll[session(id: nil, kind: "interactive", status: "busy", session_id: "uuid-1")]
      expect(described_class.diff(*poll[session(id: nil, kind: "interactive", status: "waiting", session_id: "uuid-1")])).to be_empty
    end

    it "says nothing for a snoozed or settled row, and nothing for one you attached to" do
      poll[working]
      store.snooze("abc12345", :h1)
      expect(described_class.diff(*poll[done])).to be_empty
      store.wake("abc12345")
      store.settle("abc12345")
      expect(described_class.diff(*poll[done])).to be_empty
      poll[blocked]
      store.acknowledge("abc12345")
      expect(described_class.diff(*poll[blocked])).to be_empty
    end

    it "says nothing for a row that only came back from Settled or Snoozed" do
      poll[done]
      store.settle("abc12345")
      before = store.sections
      store.wake("abc12345") # stands in for gh un-settling a row whose open PR the cache did not know
      expect(described_class.diff(before, store.sections)).to be_empty
      store.snooze("abc12345", :m15)
      before = store.sections
      clock.advance(16 * 60)
      expect(described_class.diff(before, store.sections)).to be_empty
    end

    it "speaks for a snoozed row that woke because it became blocked, and for a pinned one" do
      poll[working]
      store.snooze("abc12345", :h1)
      expect(described_class.diff(*poll[blocked]).map(&:kind)).to eq(["needs you"])
      poll[working]
      store.toggle_pin("abc12345")
      expect(described_class.diff(*poll[blocked]).map(&:kind)).to eq(["needs you"])
    end
  end

  describe "#deliver" do
    let(:runs) { [] }
    let(:status) { instance_double(Process::Status, success?: true, exitstatus: 0) }
    let(:result) { ClaudeInbox::Subprocess::Result.new("", "", status) }
    let(:notifier) {
      described_class.new(app: ClaudeInbox::NotifierApp.disabled, run: ->(*argv) {
        runs << argv
        result
      })
    }

    it "only primes on the first call, then runs terminal-notifier for each change" do
      notifier.deliver(*poll[blocked])
      sleep 0.05
      expect(runs).to be_empty
      notifier.deliver(*poll[session(state: "working"), session(id: "def67890", state: "blocked", name: "other")])
      wait_for { runs.size >= 1 }
      expect(runs).to eq([[*ClaudeInbox::NotifierApp::FALLBACK, "-title", "other", "-message", "🔴 needs you", "-group", "def67890"]])
    end

    context "with no terminal-notifier on PATH" do
      let(:status) { instance_double(Process::Status, success?: false, exitstatus: 127) }

      it "says so once and stops trying" do
        notices = []
        notifier.deliver(*poll[working])
        notifier.deliver(*poll[blocked]) { |msg| notices << msg }
        wait_for { notices.size >= 1 }
        notifier.deliver(*poll[done]) { |msg| notices << msg }
        sleep 0.05
        expect(notices).to eq(["terminal-notifier not found"])
        expect(runs.size).to eq(1)
      end
    end

    it "sends nothing when disabled" do
      disabled = described_class.new(app: ClaudeInbox::NotifierApp.disabled, run: ->(*argv) {
        runs << argv
        result
      }, enabled: false)
      disabled.deliver(*poll[working])
      disabled.deliver(*poll[blocked])
      sleep 0.05
      expect(runs).to be_empty
    end
  end
end
