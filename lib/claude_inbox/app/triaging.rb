# frozen_string_literal: true

module ClaudeInbox
  class App
    # The edits of the selected row that live in our own store: snooze, wake,
    # pin, settle, alias and linked pull request, with the two guards they
    # share. Owns no state; every edit goes through the store.
    module Triaging
      private

      # Guard for snooze/wake/alias: anything with a key, since those live in
      # our own store. A terminal you are sitting in is the one exception.
      def require_storable
        s = selected_session
        return true if @selected&.row? && !s&.terminal?
        notice("you're in that terminal right now — nothing to snooze") if s&.terminal?
        false
      end

      # The edits with no request form, which a second inbox cannot keep.
      def require_writable(verb)
        return true if @store.writable?
        notice("another claude-inbox owns state.json — #{verb} there")
        false
      end

      def wake_selected
        @store.wake(@selected.key) if require_storable
      end

      def toggle_pin_selected
        @store.toggle_pin(@selected.key) if require_storable
      end

      def settle_selected
        return unless require_storable
        @store.settle(@selected.key)
        notice("settled — u brings it back")
      end

      def open_snooze_menu
        return unless require_storable
        @modal = Dialog::Snooze.new(@selected.key)
      end

      def snooze_chosen
        @store.snooze(@modal.id, @modal.choice)
        @modal = nil
      end

      def open_alias_editor
        return unless require_storable && require_writable("rename")
        current = @store.alias_for(@selected.key) || ""
        @modal = Dialog::Prompt.new(:alias, @selected.key, current)
      end

      def open_pr_editor
        return unless require_storable && require_writable("link a pull request")
        current = @store.pr_for(@selected.key) || selected_session&.pr&.url || ""
        @modal = Dialog::Prompt.new(:pr, @selected.key, current)
      end

      def save_prompt
        value = @modal.value.strip
        if @modal.kind == :alias
          @store.set_alias(@modal.id, value)
        elsif value.empty? || PullRequests.valid_url?(value)
          @store.set_pr(@modal.id, value)
          @poller.soon
        else
          return notice("that's not a github.com pull request url")
        end
        @modal = nil
      end
    end
  end
end
