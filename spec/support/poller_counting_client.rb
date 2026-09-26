# frozen_string_literal: true

# The fixture's sessions, with a mark on `polls` for every list the worker
# asks for, so a spec can wait for the thread to have polled.
class PollerCountingClient < ClaudeInbox::FixtureClient
  def polls = (@polls ||= Queue.new)

  def list
    polls << true
    super
  end
end
