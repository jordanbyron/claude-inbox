# frozen_string_literal: true

module ClaudeInbox
  class Store
    # What the cursor is on: a row, by its key, or a fold, by its section name.
    Selection = Data.define(:kind, :key) do
      def self.row(key) = new(kind: :row, key: key)

      def self.fold(section) = new(kind: :fold, key: section)

      def row? = kind == :row

      def fold? = kind == :fold
    end
  end
end
