# frozen_string_literal: true

module ClaudeInbox
  class App
    # The newer-release check on the first step, the header's word on it,
    # and U: install and relaunch.
    module Updating
      private

      # Once, on the first step: a stale cache means a network round trip, so
      # it runs off the main thread. A laptop that is offline stays quiet
      # rather than show an error at every launch; U says what went wrong.
      def ensure_update_checked
        return if @update_status
        @update_status = @updater ? "checking for updates…" : "update check is off — claude-inbox update installs the latest"
        return unless @updater
        in_background do
          @queue << [:update, @updater.check]
        rescue Updater::Error => e
          @queue << [:update, nil, e.message]
        end
      end

      def update_checked(update, failure = nil)
        @update = update
        @snapshot.update = update&.notice
        @update_status = failure ? "couldn't check for updates: #{failure}" : "up to date"
      end

      # The header's line once a newer release is known; nil until then.
      def update_notice
        "#{@update.notice} · U updates" if @update
      end

      # The install prints on the real screen, and the relaunch replaces this
      # process. A failed install relaunches this version instead, once its
      # error has been read, rather than leave the shell showing.
      def update_inbox
        return notice(@update_status) unless @update
        @terminal.release do
          @out.puts @update.installing
          applied = @updater.apply
          @out.puts applied.output unless applied.output.empty?
          @terminal.pause unless applied.success?
          relaunch
        end
      end

      def relaunch
        @updater.relaunch(@argv)
      rescue SystemCallError => e
        @error = "relaunch failed: #{e.message}"
      end
    end
  end
end
