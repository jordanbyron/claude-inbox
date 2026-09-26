# frozen_string_literal: true

require_relative "../lib/claude_inbox/poller"

RSpec.describe ClaudeInbox::Poller do
  let(:client) do
    Class.new(ClaudeInbox::FixtureClient) {
      def removed = (@removed ||= [])

      def rm(id)
        removed << id
        true
      end
    }.new(fixture_path("agents.json"))
  end

  # Pinned: the reaper's 14-day cutoff against the fixture's startedAt
  # decides how many rows are due, and the wall clock keeps moving it.
  let(:clock) { -> { Time.at(1_789_604_500) } }
  let(:store) { ClaudeInbox::Store.new(path: nil, clock: clock) }
  let(:queue) { Queue.new }

  def poller(reaper: ClaudeInbox::Reaper.disabled, interval: ClaudeInbox::Poller::INTERVAL)
    ClaudeInbox::Poller.new(
      client: client, store: store, reaper: reaper, queue: queue, interval: interval, clock: clock,
      pull_requests: ClaudeInbox::PullRequests.new(cache_path: nil, resolved_path: nil, gh: nil)
    )
  end

  def messages = Array.new(queue.size) { queue.pop(true) }

  def published_ids(msgs) = msgs.filter_map { |kind, list| list.map(&:id) if kind == :sessions }

  it "hands the list over as sessions on the queue" do
    poller.once
    msgs = messages
    expect(msgs.map(&:first)).to eq([:sessions])
    expect(published_ids(msgs).first).to include("f23c8673")
  end

  it "reports a failed poll as an error instead of raising" do
    client.define_singleton_method(:list) { raise "daemon gone" }
    poller.once
    expect(messages).to eq([[:error, "daemon gone"]])
  end

  describe "the reaper" do
    it "is off unless something arms it, so a poll on its own deletes nothing" do
      poller.once
      expect(client.removed).to be_empty
      expect(published_ids(messages).first).to include("f23c8673")
    end

    def drain = messages.each { |kind, list| store.update(list) if kind == :sessions }

    def shown = store.sessions.map(&:id)

    it "keeps what it reaped out of the frame, from the first hand-over on" do
      reaper = Class.new {
        def due(_sessions, _now) = %w[f23c8673]

        def sweep(_sessions, _now) = %w[f23c8673]

        def report(keys) = "reaped #{keys.join(" ")}"
      }.new
      poller(reaper: reaper).once
      msgs = messages
      expect(msgs.assoc(:notice)[1]).to eq("reaped f23c8673")

      store.update(msgs.first[1])
      expect(shown).not_to include("f23c8673")
      msgs.each { |kind, list| store.update(list) if kind == :sessions }
      expect(shown).not_to include("f23c8673")
    end

    it "brings a row back when its reap was refused" do
      reaper = Class.new {
        def due(_sessions, _now) = %w[f23c8673]

        def sweep(_sessions, _now) = []

        def report(keys) = "reaped #{keys.join(" ")}"
      }.new
      poller(reaper: reaper).once
      drain
      expect(shown).to include("f23c8673")
    end

    it "releases what it hid when the sweep itself fails" do
      reaper = Class.new {
        def due(_sessions, _now) = %w[f23c8673]

        def sweep(_sessions, _now) = raise(Errno::EACCES, "reaped.log")

        def report(keys) = "reaped #{keys.join(" ")}"
      }.new
      poller(reaper: reaper).once
      msgs = messages
      expect(msgs.assoc(:error)[1]).to include("reaped.log")
      msgs.each { |kind, list| store.update(list) if kind == :sessions }
      expect(shown).to include("f23c8673")
    end

    it "keeps a row the user deleted hidden even when the reaper let it go the same poll" do
      reaper = Class.new {
        def initialize(store) = @store = store

        def due(_sessions, _now) = %w[f23c8673]

        def sweep(_sessions, _now)
          @store.forget("f23c8673")
          []
        end

        def report(keys) = "reaped #{keys.join(" ")}"
      }.new(store)
      poller(reaper: reaper).once
      drain
      expect(shown).not_to include("f23c8673")
    end

    # Every hand-over after the sweep carries the reaped key; a list without
    # it is what tells the store the daemon dropped it.
    it "keeps a reaped row hidden on later polls while the daemon still lists it" do
      client.define_singleton_method(:rm) do |id|
        @refused ||= id
        raise ClaudeInbox::AgentsClient::Error, "rm failed: unpushed commits" if id == @refused
        removed << id
        true
      end
      reaper = ClaudeInbox::Reaper.new(client, store, log_path: File::NULL, enabled: true)

      poller(reaper: reaper).once
      drain
      poller(reaper: reaper).once
      drain
      refused = client.instance_variable_get(:@refused)
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
    def drain_into_store(msgs) = msgs.each { |kind, list| store.update(list) if kind == :sessions }

    it "does not bring the row back until the daemon has dropped it" do
      poller.once
      drain_into_store(messages)
      expect(store.sections.all.map(&:id)).to include("f23c8673")

      client.rm("f23c8673")
      store.forget("f23c8673")
      poller.once
      msgs = messages
      expect(published_ids(msgs).first).to include("f23c8673")
      drain_into_store(msgs)
      expect(store.sections.all.map(&:id)).not_to include("f23c8673")
      expect(store.sessions.map(&:id)).not_to include("f23c8673")
    end
  end

  # The worker is a real thread here, so these wait for it to act rather than
  # assume it has, and only ever assert that something did *not* happen after
  # giving it far longer than it needs.
  describe "the worker" do
    let(:client) do
      Class.new(ClaudeInbox::FixtureClient) {
        def polls = (@polls ||= Queue.new)

        def list
          polls << true
          super
        end
      }.new(fixture_path("agents.json"))
    end

    def polls = client.polls.size

    def wait_for_polls(n)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      sleep 0.01 until polls >= n || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      polls
    end

    after { @poller&.stop }

    it "polls once when started" do
      @poller = poller(interval: 60)
      @poller.start
      expect(wait_for_polls(1)).to eq(1)
    end

    it "collapses a burst of wake-ups into one poll" do
      @poller = poller(interval: 60)
      @poller.soon
      @poller.soon
      @poller.start
      expect(wait_for_polls(1)).to eq(1)
      sleep 0.2
      expect(polls).to eq(1)
    end

    it "polls again on the interval" do
      @poller = poller(interval: 0.05)
      @poller.start
      expect(wait_for_polls(2)).to be >= 2
    end

    it "skips the poll while paused and catches up on resume" do
      @poller = poller(interval: 60)
      @poller.pause
      @poller.start
      @poller.soon
      sleep 0.2
      expect(polls).to eq(0)

      @poller.resume
      expect(wait_for_polls(1)).to eq(1)
    end

    it "can be stopped before it was started" do
      poller.stop
    end

    it "starts one worker however many times start is called" do
      @poller = poller(interval: 60)
      @poller.start
      @poller.start
      expect(wait_for_polls(1)).to eq(1)
      sleep 0.2
      expect(polls).to eq(1)
    end

    it "reports a poll that blew the stack and keeps polling" do
      client.define_singleton_method(:list) do
        polls << true
        raise SystemStackError, "stack level too deep"
      end
      @poller = poller(interval: 60)
      @poller.start
      expect(wait_for_polls(1)).to eq(1)
      expect(queue.pop).to eq([:error, "stack level too deep"])
      client.singleton_class.remove_method(:list)

      @poller.soon
      expect(wait_for_polls(2)).to eq(2)
      expect(queue.pop.first).to eq(:sessions)
    end
  end
end
