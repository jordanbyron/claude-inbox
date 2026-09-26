# frozen_string_literal: true

RSpec.describe ClaudeInbox::Poller do
  subject(:poller) do
    described_class.new(
      client: client, store: store, reaper: reaper, queue: queue, interval: interval, clock: clock,
      pull_requests: ClaudeInbox::PullRequests.new(cache_path: nil, resolved_path: nil, gh: nil)
    )
  end

  let(:client) { RecordingClient.new }
  let(:reaper) { ClaudeInbox::Reaper.disabled }
  let(:interval) { described_class::INTERVAL }

  # Pinned: the reaper's 14-day cutoff against the fixture's startedAt
  # decides how many rows are due, and the wall clock keeps moving it.
  let(:clock) { -> { Time.at(1_789_604_500) } }
  let(:store) { ClaudeInbox::Store.new(path: nil, clock: clock) }
  let(:queue) { Queue.new }

  describe "#once" do
    # Read after the poll: everything it put on the queue, in order.
    let(:messages) do
      poller.once
      Array.new(queue.size) { queue.pop(true) }
    end
    let(:published) { messages.filter_map { |kind, list| list.map(&:id) if kind == :sessions } }
    let(:shown) do
      messages.each { |kind, list| store.update(list) if kind == :sessions }
      store.sessions.map(&:id)
    end

    it "hands the list over as sessions on the queue" do
      expect(messages.map(&:first)).to eq([:sessions])
      expect(published.first).to include("f23c8673")
    end

    it "reports a failed poll as an error instead of raising" do
      allow(client).to receive(:list).and_raise("daemon gone")
      expect(messages).to eq([[:error, "daemon gone"]])
    end

    describe "the reaper" do
      it "is off unless something arms it, so a poll on its own deletes nothing" do
        expect(published.first).to include("f23c8673")
        expect(client.removed).to be_empty
      end

      context "when it is due to take a row" do
        let(:reaper) { instance_double(ClaudeInbox::Reaper, due: %w[f23c8673], sweep: %w[f23c8673]) }

        before { allow(reaper).to receive(:report) { |keys| "reaped #{keys.join(" ")}" } }

        it "keeps what it reaped out of the frame, from the first hand-over on" do
          expect(messages.assoc(:notice)[1]).to eq("reaped f23c8673")

          store.update(messages.first[1])
          expect(store.sessions.map(&:id)).not_to include("f23c8673")
          expect(shown).not_to include("f23c8673")
        end

        it "brings a row back when its reap was refused" do
          allow(reaper).to receive(:sweep).and_return([])
          expect(shown).to include("f23c8673")
        end

        it "releases what it hid when the sweep itself fails" do
          allow(reaper).to receive(:sweep).and_raise(Errno::EACCES, "reaped.log")
          expect(messages.assoc(:error)[1]).to include("reaped.log")
          expect(shown).to include("f23c8673")
        end

        it "keeps a row the user deleted hidden even when the reaper let it go the same poll" do
          allow(reaper).to receive(:sweep) do
            store.forget("f23c8673")
            []
          end
          expect(shown).not_to include("f23c8673")
        end
      end

      # Every hand-over after the sweep carries the reaped key; a list without
      # it is what tells the store the daemon dropped it.
      context "when armed and the first rm is refused" do
        let(:reaper) { ClaudeInbox::Reaper.new(client, store, log_path: File::NULL, enabled: true) }
        let(:refused) { [] }

        before do
          allow(client).to receive(:rm).and_wrap_original do |rm, id|
            refused << id if refused.empty?
            raise ClaudeInbox::AgentsClient::Error, "rm failed: unpushed commits" if refused.include?(id)
            rm.call(id)
          end
          2.times do
            poller.once
            queue.size.times { queue.pop.then { |kind, list| store.update(list) if kind == :sessions } }
          end
        end

        it "keeps a reaped row hidden on later polls while the daemon still lists it" do
          reaped = client.removed.dup
          expect(reaped.size).to eq(1)
          expect(store.sessions.map(&:id)).to include(refused.first)
          expect(store.sessions.map(&:id)).not_to include(reaped.first)

          2.times do
            poller.once
            queue.size.times { queue.pop.then { |kind, list| store.update(list) if kind == :sessions } }
          end
          expect(store.sessions.map(&:id)).not_to include(reaped.first)
          expect(client.removed).to eq(reaped)
        end
      end
    end

    # App drains the queue into the store, so the race is settled there: `rm`
    # has returned and `forget` run, but `claude agents` still lists the id on
    # the poll that follows.
    context "when a delete lands while a poll is in flight" do
      before do
        poller.once
        queue.size.times { queue.pop.then { |kind, list| store.update(list) if kind == :sessions } }
      end

      it "does not bring the row back until the daemon has dropped it" do
        expect(store.sections.all.map(&:id)).to include("f23c8673")
        client.rm("f23c8673")
        store.forget("f23c8673")

        expect(published.first).to include("f23c8673")
        expect(shown).not_to include("f23c8673")
        expect(store.sections.all.map(&:id)).not_to include("f23c8673")
      end
    end
  end

  # The worker is a real thread here, so these wait for it to act rather than
  # assume it has, and only ever assert that something did *not* happen after
  # giving it far longer than it needs.
  describe "the worker" do
    let(:client) { PollerCountingClient.new(fixture_path("agents.json")) }
    let(:interval) { 60 }

    after { poller.stop }

    it "polls once when started" do
      poller.start
      expect(wait_for { client.polls.size >= 1 }).to be(true)
      expect(client.polls.size).to eq(1)
    end

    it "collapses a burst of wake-ups into one poll" do
      poller.soon
      poller.soon
      poller.start
      expect(wait_for { client.polls.size >= 1 }).to be(true)
      sleep 0.2
      expect(client.polls.size).to eq(1)
    end

    context "with a short interval" do
      let(:interval) { 0.05 }

      it "polls again on the interval" do
        poller.start
        expect(wait_for { client.polls.size >= 2 }).to be(true)
      end
    end

    it "skips the poll while paused and catches up on resume" do
      poller.pause
      poller.start
      poller.soon
      sleep 0.2
      expect(client.polls.size).to eq(0)

      poller.resume
      expect(wait_for { client.polls.size >= 1 }).to be(true)
      expect(client.polls.size).to eq(1)
    end

    it "can be stopped before it was started" do
      poller.stop
    end

    it "starts one worker however many times start is called" do
      poller.start
      poller.start
      expect(wait_for { client.polls.size >= 1 }).to be(true)
      sleep 0.2
      expect(client.polls.size).to eq(1)
    end

    it "reports a poll that blew the stack and keeps polling" do
      allow(client).to receive(:list) do
        client.polls << true
        raise SystemStackError, "stack level too deep"
      end
      poller.start
      expect(wait_for { client.polls.size >= 1 }).to be(true)
      expect(queue.pop).to eq([:error, "stack level too deep"])
      allow(client).to receive(:list).and_call_original

      poller.soon
      expect(wait_for { client.polls.size >= 2 }).to be(true)
      expect(client.polls.size).to eq(2)
      expect(queue.pop.first).to eq(:sessions)
    end
  end
end
