# frozen_string_literal: true

# The selections a Store::Sections hands the cursor: a row by key, or a fold.
module StoreSectionsHelpers
  def row(key) = ClaudeInbox::Store::Selection.row(key)

  def fold(name) = ClaudeInbox::Store::Selection.fold(name)
end

RSpec.configure { |config| config.include StoreSectionsHelpers, :store_sections }
