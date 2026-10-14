# frozen_string_literal: true

module ClaudeInbox
  class App
    # X stops the selected session and ctrl-x deletes it, both behind the one
    # confirm, with the daemon asked off the main thread. Owns no state.
    module Stopping
      private

      def open_confirm(kind)
        return unless require_actionable
        @modal = Dialog::Confirm.new(kind, @selected.key)
      end

      def stop_session(id)
        in_background do
          @client.stop(id)
          @poller.soon
        end
      end

      def delete_session(id)
        notice("deleting #{id}…")
        in_background do
          @client.rm(id)
          @store.forget(id)
          @queue << [:notice, "deleted #{id}"]
          @poller.soon
        end
      end
    end
  end
end
