# frozen_string_literal: true

module ClaudeInbox
  class App
    # Where the cursor is in the sectioned, foldable list and how it moves:
    # j/k, Tab, the folds, a click, and the row a spawn asked to land on.
    # The only writer of the selection; the rest of App reads it.
    module Navigating
      private

      # Remembers where the frame put the rows, so a click can find one.
      def placed(frame)
        @row_items = frame.items
        @list_width = frame.list_width
        @top = frame.top
      end

      # The row to land on once a poll lists it, as after a spawn.
      def select_later(id)
        @pending_select = id
      end

      def ensure_selection(sections)
        stops = sections.selections(@expanded)
        pending = @pending_select && Store::Selection.row(@pending_select)
        if pending && stops.include?(pending)
          select(pending)
          @pending_select = nil
          return
        end
        return if stops.include?(@selected)
        select(stops.first)
      end

      def select(selection)
        @selected = selection
        @peek.select(selected_session)
      end

      def session_for(key) = @store.sessions.find { |s| s.key == key }

      def selected_session = session_for(@selected&.key)

      def page = [Renderer.body_height(@terminal.size[1]), 1].max

      def move(delta)
        stops = filtered.selections(@expanded)
        return if stops.empty?
        idx = stops.index(@selected) || 0
        select(stops[(idx + delta).clamp(0, stops.size - 1)])
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

      # The foldable section the cursor is currently on or inside, if any.
      def current_fold_section
        name = filtered.section_of(@selected)
        name if Store::FOLDABLE_SECTIONS.include?(name)
      end

      def set_expanded(value)
        name = current_fold_section
        @expanded[name] = value if name
      end

      def toggle_expanded = set_expanded(!@expanded[current_fold_section])

      # Clicking a row selects it and attaches, same as landing on it with
      # j/k and pressing Enter — activate already knows how to expand a fold
      # or refuse a terminal/remote row, so this doesn't repeat that.
      def click_row(row, col)
        return if @list_width && col > @list_width
        item = row_item_at(row)
        return unless item
        select(item)
        activate
      end

      # The wrapped detail line under a two-line row ("↳ ~/code/x") carries
      # no item of its own; a click there resolves to the row above it.
      def row_item_at(row)
        idx = row - 1
        @row_items[idx] || (@row_items[idx - 1] if idx > 0 && @row_items[idx - 1]&.row?)
      end
    end
  end
end
