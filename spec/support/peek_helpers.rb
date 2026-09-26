# frozen_string_literal: true

# Builders and steps for the Peek spec; they call the group's `peek`, `clock`
# and `logs` lets.
module PeekHelpers
  def row(**attrs) = ClaudeInbox::Store::Row.new(session: session(**attrs), entry: nil)

  def on(key) = ClaudeInbox::Store::Selection.row(key)

  def fetch(r)
    peek.select(on(r.key), r.session)
    peek.toggle
    clock.advance(ClaudeInbox::Logs::DEBOUNCE)
    logs.tick
    expect(wait_for { logs.cached(r.session.id) }).not_to be_nil
  end
end

RSpec.configure { |config| config.include PeekHelpers, :peek }
