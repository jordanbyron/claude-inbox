# frozen_string_literal: true

RSpec.describe ClaudeInbox::Poller, :poller do
  let(:client) { RecordingClient.new }

  # Pinned: the reaper's 14-day cutoff against the fixture's startedAt
  # decides how many rows are due, and the wall clock keeps moving it.
  let(:clock) { -> { Time.at(1_789_604_500) } }
  let(:store) { ClaudeInbox::Store.new(path: nil, clock: clock) }
  let(:queue) { Queue.new }

  it "hands the list over as sessions on the queue" do
    poller.once
    msgs = messages
    expect(msgs.map(&:first)).to eq([:sessions])
    expect(published_ids(msgs).first).to include("f23c8673")
  end

  it "reports a failed poll as an error instead of raising" do
    allow(client).to receive(:list).and_raise("daemon gone")
    poller.once
    expect(messages).to eq([[:error, "daemon gone"]])
  end

  describe "the reaper" do
    let(:reaper) { instance_double(ClaudeInbox::Reaper, due: %w[f23c8673], sweep: %w[f23c8673]) }

    before { allow(reaper).to receive(:report) { |keys| "reaped #{keys.join(" ")}" } }

    it "is off unless something arms it, so a poll on its own deletes nothing" do
      poller.once
      expect(client.removed).to be_empty
      expect(published_ids(messages).first).to include("f23c8673")
    end

    it "keeps what it reaped out of the frame, from the first hand-over on" do
      poller(reaper: reaper).once
      msgs = messages
      expect(msgs.assoc(:notice)[1]).to eq("reaped f23c8673")

      store.update(msgs.first[1])
      expect(shown).not_to include("f23c8673")
      msgs.each { |kind, list| store.update(list) if kind == :sessions }
      expect(shown).not_to include("f23c8673")
    end

    it "brings a row back when its reap was refused" do
      allow(reaper).to receive(:sweep).and_return([])
      poller(reaper: reaper).once
      drain
      expect(shown).to include("f23c8673")
    end

    it "releases what it hid when the sweep itself fails" do
      allow(reaper).to receive(:sweep).and_raise(Errno::EACCES, "reaped.log")
      poller(reaper: reaper).once
      msgs = messages
      expect(msgs.assoc(:error)[1]).to include("reaped.log")
      msgs.each { |kind, list| store.update(list) if kind == :sessions }
      expect(shown).to include("f23c8673")
    end

    it "keeps a row the user deleted hidden even when the reaper let it go the same poll" do
      allow(reaper).to receive(:sweep) do
        store.forget("f23c8673")
        []
      end
      poller(reaper: reaper).once
      drain
      expect(shown).not_to include("f23c8673")
    end

    # Every hand-over after the sweep carries the reaped key; a list without
    # it is what tells the store the daemon dropped it.
    it "keeps a reaped row hidden on later polls while the daemon still lists it" do
      refused = nil
      allow(client).to receive(:rm).and_wrap_original do |rm, id|
        refused ||= id
        raise ClaudeInbox::AgentsClient::Error, "rm failed: unpushed commits" if id == refused
        rm.call(id)
      end
      reaper = ClaudeInbox::Reaper.new(client, store, log_path: File::NULL, enabled: true)

      poller(reaper: reaper).once
      drain
      poller(reaper: reaper).once
      drain
      reaped = client.removed.dup
      expect(reaped.size).to eq(1)
      expect(shown).to include(refused)
      expect(shown).not_to include(reaped.first)

      2.times do
        poller(reaper: reaper).once
        drain
      end
      expect(shown).not_to include(reaped.first)
      expect(client.removed).to eq(reaped)
    end
  end

  # App drains the queue into the store, so the race is settled there: `rm`
  # has returned and `forget` run, but `claude agents` still lists the id on
  # the poll that follows.
  describe "a delete while a poll is in flight" do
    it "does not bring the row back until the daemon has dropped it" do
      poller.once
      drain(messages)
      expect(store.sections.all.map(&:id)).to include("f23c8673")

      client.rm("f23c8673")
      store.forget("f23c8673")
      poller.once
      msgs = messages
      expect(published_ids(msgs).first).to include("f23c8673")
      drain(msgs)
      expect(store.sections.all.map(&:id)).not_to include("f23c8673")
      expect(store.sessions.map(&:id)).not_to include("f23c8673")
    end
  end

  # The worker is a real thread here, so these wait for it to act rather than
  # assume it has, and only ever assert that something did *not* happen after
  # giving it far longer than it needs.
  describe "the worker" do
    subject(:worker) { poller(interval: interval) }

    let(:client) { PollerCountingClient.new(fixture_path("agents.json")) }
    let(:interval) { 60 }

    after { worker.stop }

    it "polls once when started" do
      worker.start
      expect(wait_for_polls(1)).to eq(1)
    end

    it "collapses a burst of wake-ups into one poll" do
      worker.soon
      worker.soon
      worker.start
      expect(wait_for_polls(1)).to eq(1)
      sleep 0.2
      expect(polls).to eq(1)
    end

    context "with a short interval" do
      let(:interval) { 0.05 }

      it "polls again on the interval" do
        worker.start
        expect(wait_for_polls(2)).to be >= 2
      end
    end

    it "skips the poll while paused and catches up on resume" do
      worker.pause
      worker.start
      worker.soon
      sleep 0.2
      expect(polls).to eq(0)

      worker.resume
      expect(wait_for_polls(1)).to eq(1)
    end

    it "can be stopped before it was started" do
      worker.stop
    end

    it "starts one worker however many times start is called" do
      worker.start
      worker.start
      expect(wait_for_polls(1)).to eq(1)
      sleep 0.2
      expect(polls).to eq(1)
    end

    it "reports a poll that blew the stack and keeps polling" do
      allow(client).to receive(:list) do
        client.polls << true
        raise SystemStackError, "stack level too deep"
      end
      worker.start
      expect(wait_for_polls(1)).to eq(1)
      expect(queue.pop).to eq([:error, "stack level too deep"])
      allow(client).to receive(:list).and_call_original

      worker.soon
      expect(wait_for_polls(2)).to eq(2)
      expect(queue.pop.first).to eq(:sessions)
    end
  end
end
