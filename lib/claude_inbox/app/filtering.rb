# frozen_string_literal: true

module ClaudeInbox
  class App
    # The `/` filter line: the text typed into it, whether it has the keys,
    # and the sections that match it.
    module Filtering
      private

      def filter_editing? = @filter_editing

      def filter = @filter

      def filtered(sections = @store.sections) = sections.matching(@filter&.to_s)

      def start_filter
        @filter ||= TextBuffer.new
        @filter_editing = true
      end

      def clear_filter
        @filter = nil
        @filter_editing = false
      end

      def handle_line_key(name, key)
        case name
        when :escape then clear_filter
        when :return, :enter then @filter_editing = false
        when :backspace, :ctrl_h
          @filter.empty? ? clear_filter : @filter.press(name, key)
        else
          @filter.press(name, key)
        end
      end
    end
  end
end
