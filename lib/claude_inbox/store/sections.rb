# frozen_string_literal: true

module ClaudeInbox
  class Store
    # The Rows of one poll, grouped and ordered, and where the cursor may land among them.
    Sections = Struct.new(:pinned, :needs_you, :active, :snoozed, :settled) do
      def each_section = SECTIONS.each { |k| yield k, self[k] }

      def all = SECTIONS.flat_map { |k| self[k] }

      def row(selection)
        all.find { |r| r.key == selection.key } if selection&.row?
      end

      def matching(query)
        return self if query.nil? || query.empty?
        self.class.new(**to_h.transform_values { |rows| rows.select { |r| r.matches?(query) } })
      end

      def section_of(selection)
        return nil if selection.nil?
        return selection.key if selection.fold?
        each_section { |name, rows| return name if rows.any? { |r| r.key == selection.key } }
        nil
      end

      def selections(expanded) = stops(expanded).flat_map(&:last)

      # `[name, selection]` per section: its first row, or the fold standing in for them.
      def heads(expanded)
        stops(expanded).filter_map { |name, stops| [name, stops.first] if stops.any? }
      end

      private

      # An empty fold is left out, since there is nothing under it to open.
      def stops(expanded)
        SECTIONS.filter_map do |name|
          rows = self[name]
          if !Store.folded?(name, expanded) then [name, rows.select(&:selectable?).map { |r| Selection.row(r.key) }]
          elsif rows.any? then [name, [Selection.fold(name)]]
          end
        end
      end
    end
  end
end
