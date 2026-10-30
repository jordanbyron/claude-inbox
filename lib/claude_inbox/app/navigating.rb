# frozen_string_literal: true

module ClaudeInbox
  class App
    # Where the cursor is in the sectioned, foldable list and how it moves.
    # The only writer of the selection; the rest of App reads it.
    module Navigating
      ARRIVAL_SECONDS = 4

      private

      def arrival(now) = @arrival&.then { |a, until_at| a if now < until_at }

      # The row to land on once a poll lists it, as after a spawn.
      def select_later(id)
        @pending_select = id
      end

      # A requested row behind a fold lands on the fold line, which lights
      # up for a few seconds naming the arrival; the fold stays shut, since
      # a folded session is one you chose not to watch. Left pending, the
      # request would fire whenever the row next surfaced, taking the cursor
      # from wherever you had moved it since.
      def ensure_selection(sections)
        pending = @pending_select && Store::Selection.row(@pending_select)
        if pending && (name = sections.section_of(pending))
          if Store.folded?(name, @expanded)
            @arrival = [Renderer::Arrival.new(section: name, label: label_for(pending.key)), Time.now + ARRIVAL_SECONDS]
            select(Store::Selection.fold(name))
          else
            select(pending)
          end
          @pending_select = nil
          return
        end
        stops = sections.selections(@expanded)
        return if stops.include?(@selected)
        select(stops.first)
      end

      def select(selection)
        @selected = selection
      end

      def session_for(key) = @store.sessions.find { |s| s.key == key }

      def selected_session = session_for(@selected&.key)

      # The alias if one is set, as the row shows it, rather than the bare id.
      def label_for(key) = session_for(key)&.then { |s| @store.row(s).label } || key

      def page = [Renderer.body_height(@terminal.size[1]), 1].max

      def move(delta)
        stops = filtered.selections(@expanded)
        return if stops.empty?
        idx = stops.index(@selected) || 0
        select(stops[(idx + delta).clamp(0, stops.size - 1)])
      end

      # Before a row leaves the list: the stop below it, or above it at the
      # bottom, so working down a section doesn't throw the cursor to the top.
      def select_neighbour
        stops = filtered.selections(@expanded)
        idx = stops.index(@selected)
        rest = stops - [@selected]
        select(rest[idx.clamp(..rest.size - 1)]) if idx && rest.any?
      end

      # Tab / Shift-Tab: first selectable row of the next / previous section.
      def jump_section(dir)
        sections = filtered
        heads = sections.heads(@expanded)
        return if heads.empty?
        current = sections.section_of(@selected)
        idx = heads.index { |name, _| name == current } || -1
        select(heads[(idx + dir) % heads.size].last)
      end

      def current_fold_section
        name = filtered.section_of(@selected)
        name if Store::FOLDABLE_SECTIONS.include?(name)
      end

      # Opening lands on the section's first row and closing on its fold
      # line, rather than leaving the cursor on a stop that just vanished.
      def set_expanded(value)
        name = current_fold_section
        return if name.nil? || !!@expanded[name] == value
        @expanded[name] = value
        select(value ? filtered.heads(@expanded).to_h.fetch(name, @selected) : Store::Selection.fold(name))
      end

      def toggle_expanded = set_expanded(!@expanded[current_fold_section])

      # Left to activate, as Enter is, to expand a fold or refuse a
      # terminal or remote row.
      def click_row(row)
        item = row_item_at(row)
        return unless item
        select(item)
        activate
      end

      # The wrapped detail line under a two-line row ("↳ ~/code/x") carries
      # no item of its own; a click there resolves to the row above it.
      def row_item_at(row)
        idx = row - 1
        @frame.items[idx] || (@frame.items[idx - 1] if idx > 0 && @frame.items[idx - 1]&.row?)
      end
    end
  end
end
