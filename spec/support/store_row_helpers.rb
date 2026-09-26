# frozen_string_literal: true

# A Store::Row over a session and an entry hash, or no entry for nil.
module StoreRowHelpers
  def row(session, entry) = ClaudeInbox::Store::Row.new(session: session, entry: entry && ClaudeInbox::Store::Entry.new(entry))
end

RSpec.configure { |config| config.include StoreRowHelpers, :store_row }
