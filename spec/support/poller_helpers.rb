# frozen_string_literal: true

# Builds the poller and reads what it handed over; uses the group's
# `client`, `store`, `queue` and `clock`.
module PollerHelpers
  def poller(reaper: ClaudeInbox::Reaper.disabled, interval: ClaudeInbox::Poller::INTERVAL)
    ClaudeInbox::Poller.new(
      client: client, store: store, reaper: reaper, queue: queue, interval: interval, clock: clock,
      pull_requests: ClaudeInbox::PullRequests.new(cache_path: nil, resolved_path: nil, gh: nil)
    )
  end

  def messages = Array.new(queue.size) { queue.pop(true) }

  def published_ids(msgs) = msgs.filter_map { |kind, list| list.map(&:id) if kind == :sessions }

  def drain(msgs = messages) = msgs.each { |kind, list| store.update(list) if kind == :sessions }

  def shown = store.sessions.map(&:id)

  def polls = client.polls.size

  def wait_for_polls(n)
    wait_for { polls >= n }
    polls
  end
end

RSpec.configure { |config| config.include PollerHelpers, :poller }
