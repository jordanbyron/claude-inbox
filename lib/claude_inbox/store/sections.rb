# frozen_string_literal: true

module ClaudeInbox
  class Store
    # The Rows of one poll, grouped and ordered, and where the cursor may land among them.
    Sections = Struct.new(:pinned, :needs_you, :active, :snoozed, :settled) do
      def each_section = SECTIONS.each { |k| yield k, self[k] }

      def all = SECTIONS.flat_map { |k| self[k] }

      def row(key) = all.find { |r| r.key == key }

      def matching(query)
        return self if query.nil? || query.empty?
        self.class.new(**to_h.transform_values { |rows| rows.select { |r| r.matches?(query) } })
      end

      def section_of(key)
        return key if FOLDABLE_SECTIONS.include?(key)
        each_section { |name, rows| return name if rows.any? { |r| r.key == key } }
        nil
      end

      def selectable_keys(expanded)
        stops(expanded).flat_map { |name, rows| rows ? rows.map(&:key) : [name] }
      end

      # `[name, row]` per section, row nil where the fold itself is the stop.
      def heads(expanded)
        stops(expanded).filter_map { |name, rows| [name, rows&.first] if rows.nil? || rows.any? }
      end

      private

      # nil for a folded section, whose fold is the stop; an empty fold is
      # left out, since there is nothing under it to open.
      def stops(expanded)
        SECTIONS.filter_map do |name|
          rows = self[name]
          if !Store.folded?(name, expanded) then [name, rows.select(&:selectable?)]
          elsif rows.any? then [name, nil]
          end
        end
      end
    end
  end
end
