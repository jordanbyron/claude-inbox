# frozen_string_literal: true

module ClaudeInbox
  class Store
    # The Rows of one poll, grouped and ordered. It also knows where the
    # cursor may land, since a folded section stands in for its rows and
    # only Rows with a key take a selection.
    Sections = Struct.new(:pinned, :needs_you, :active, :snoozed, :settled) do
      def each_section = SECTIONS.each { |k| yield k, self[k] }

      def all = SECTIONS.flat_map { |k| self[k] }

      def row(key) = all.find { |r| r.key == key }

      # The rows the `/` filter keeps, in the same sections; the whole thing
      # untouched when there is no filter.
      def matching(query)
        return self if query.nil? || query.empty?
        self.class.new(**to_h.transform_values { |rows| rows.select { |r| r.matches?(query) } })
      end

      # The section a key lives in. A fold's name answers itself.
      def section_of(key)
        return key if FOLDABLE_SECTIONS.include?(key)
        each_section { |name, rows| return name if rows.any? { |r| r.key == key } }
        nil
      end

      # Everything the cursor can land on, top to bottom.
      def selectable_keys(expanded)
        stops(expanded).flat_map { |name, rows| rows ? rows.map(&:key) : [name] }
      end

      # The first stop in each section that has one, as `[name, row]`; the
      # row is nil where the fold itself is the stop.
      def heads(expanded)
        stops(expanded).filter_map { |name, rows| [name, rows&.first] if rows.nil? || rows.any? }
      end

      private

      # Per section, the selectable rows, or nil when the section is folded
      # and the cursor stops on the fold instead. An empty fold is left out:
      # there is nothing under it to open.
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
