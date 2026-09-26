# frozen_string_literal: true

# Builders shared by the Store specs; they read the group's `now`.
module StoreHelpers
  def sections(sessions, entries = {}, at = now) = ClaudeInbox::Store.sectionize(sessions, entries, at)

  def ids(rows) = rows.map(&:id)

  def pr(state) = ClaudeInbox::PullRequest.new(number: 1, url: "https://github.com/o/r/pull/1", state: state)
end

RSpec.configure { |config| config.include StoreHelpers, :store }
