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

  def poller(reaper: ClaudeInbox::Reaper.disabled)
    ClaudeInbox::Poller.new(
      client: client, store: store, reaper: reaper, queue: queue,
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
end
