# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/claude_inbox/poller"

describe ClaudeInbox::Poller do
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
    _(msgs.map(&:first)).must_equal [:sessions]
    _(published_ids(msgs).first).must_include "f23c8673"
  end

  it "reports a failed poll as an error instead of raising" do
    client.define_singleton_method(:list) { raise "daemon gone" }
    poller.once
    _(messages).must_equal [[:error, "daemon gone"]]
  end

  describe "the reaper" do
    it "is off unless something arms it, so a poll on its own deletes nothing" do
      poller.once
      _(client.removed).must_be_empty
      _(published_ids(messages).first).must_include "f23c8673"
    end

    def drain = messages.each { |kind, list| store.update(list) if kind == :sessions }

    def shown = store.sessions.map(&:id)

    it "keeps what it reaped out of the frame, from the first hand-over on" do
      reaper = Class.new {
        def due(_sessions, _now) = %w[f23c8673]

        def sweep(_sessions, _now) = %w[f23c8673]

        def log_path = File::NULL
      }.new
      poller(reaper: reaper).once
      msgs = messages
      _(msgs.assoc(:notice)[1]).must_include "reaped 1 session"

      store.update(msgs.first[1])
      _(shown).wont_include "f23c8673"
      msgs.each { |kind, list| store.update(list) if kind == :sessions }
      _(shown).wont_include "f23c8673"
    end

    it "brings a row back when its reap was refused" do
      reaper = Class.new {
        def due(_sessions, _now) = %w[f23c8673]

        def sweep(_sessions, _now) = []

        def log_path = File::NULL
      }.new
      poller(reaper: reaper).once
      drain
      _(shown).must_include "f23c8673"
    end

    it "releases what it hid when the sweep itself fails" do
      reaper = Class.new {
        def due(_sessions, _now) = %w[f23c8673]

        def sweep(_sessions, _now) = raise(Errno::EACCES, "reaped.log")

        def log_path = File::NULL
      }.new
      poller(reaper: reaper).once
      msgs = messages
      _(msgs.assoc(:error)[1]).must_include "reaped.log"
      msgs.each { |kind, list| store.update(list) if kind == :sessions }
      _(shown).must_include "f23c8673"
    end

    it "keeps a row the user deleted hidden even when the reaper let it go the same poll" do
      reaper = Class.new {
        def initialize(store) = @store = store

        def due(_sessions, _now) = %w[f23c8673]

        def sweep(_sessions, _now)
          @store.forget("f23c8673")
          []
        end

        def log_path = File::NULL
      }.new(store)
      poller(reaper: reaper).once
      drain
      _(shown).wont_include "f23c8673"
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
      _(reaped.size).must_equal 1
      _(shown).must_include refused
      _(shown).wont_include reaped.first

      2.times do
        poller(reaper: reaper).once
        drain
      end
      _(shown).wont_include reaped.first
      _(client.removed).must_equal reaped
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
      _(store.sections.all.map(&:id)).must_include "f23c8673"

      client.rm("f23c8673")
      store.forget("f23c8673")
      poller.once
      msgs = messages
      _(published_ids(msgs).first).must_include "f23c8673"
      drain_into_store(msgs)
      _(store.sections.all.map(&:id)).wont_include "f23c8673"
      _(store.sessions.map(&:id)).wont_include "f23c8673"
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
      _(wait_for_polls(1)).must_equal 1
    end

    it "collapses a burst of wake-ups into one poll" do
      @poller = poller(interval: 60)
      @poller.soon
      @poller.soon
      @poller.start
      _(wait_for_polls(1)).must_equal 1
      sleep 0.2
      _(polls).must_equal 1
    end

    it "polls again on the interval" do
      @poller = poller(interval: 0.05)
      @poller.start
      _(wait_for_polls(2)).must_be :>=, 2
    end

    it "skips the poll while paused and catches up on resume" do
      @poller = poller(interval: 60)
      @poller.pause
      @poller.start
      @poller.soon
      sleep 0.2
      _(polls).must_equal 0

      @poller.resume
      _(wait_for_polls(1)).must_equal 1
    end

    it "can be stopped before it was started" do
      poller.stop
    end

    it "starts one worker however many times start is called" do
      @poller = poller(interval: 60)
      @poller.start
      @poller.start
      _(wait_for_polls(1)).must_equal 1
      sleep 0.2
      _(polls).must_equal 1
    end

    it "reports a poll that blew the stack and keeps polling" do
      client.define_singleton_method(:list) do
        polls << true
        raise SystemStackError, "stack level too deep"
      end
      @poller = poller(interval: 60)
      @poller.start
      _(wait_for_polls(1)).must_equal 1
      _(queue.pop).must_equal [:error, "stack level too deep"]
      client.singleton_class.remove_method(:list)

      @poller.soon
      _(wait_for_polls(2)).must_equal 2
      _(queue.pop.first).must_equal :sessions
    end
  end
end
