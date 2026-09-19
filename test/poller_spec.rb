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

  let(:store) { ClaudeInbox::Store.new(path: nil) }
  let(:queue) { Queue.new }

  def poller(reaper: ClaudeInbox::Reaper.disabled, interval: ClaudeInbox::Poller::INTERVAL)
    ClaudeInbox::Poller.new(
      client: client, store: store, reaper: reaper, queue: queue, interval: interval,
      pull_requests: ClaudeInbox::PullRequests.new(cache_path: nil, resolved_path: nil, gh: nil),
      jobs_dir: fixture_path("jobs")
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

    # A reaped row has to be dropped on the way to the store, not after it
    # gets there: `update` would fold it straight back into the entry table
    # and the row would reappear for a poll. That holds for the early
    # hand-over too, the one that goes up before `claude rm` runs.
    it "keeps what it reaped out of the frame" do
      reaper = Class.new {
        def due(_sessions, _now) = %w[f23c8673]

        def sweep(_sessions, _now) = %w[f23c8673]

        def log_path = File::NULL
      }.new
      poller(reaper: reaper).once
      msgs = messages

      lists = published_ids(msgs)
      _(lists).wont_be_empty
      lists.each { |ids| _(ids).wont_include "f23c8673" }
      _(msgs.assoc(:notice)[1]).must_include "reaped 1 session"
    end

    it "brings a row back when its reap was refused" do
      reaper = Class.new {
        def due(_sessions, _now) = %w[f23c8673]

        def sweep(_sessions, _now) = []

        def log_path = File::NULL
      }.new
      poller(reaper: reaper).once

      _(published_ids(messages).last).must_include "f23c8673"
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
