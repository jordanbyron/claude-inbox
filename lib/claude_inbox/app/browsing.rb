# frozen_string_literal: true

module ClaudeInbox
  class App
    # o opens the selected session's pull request and w its claude.ai/code
    # page, through whatever opens URLs on this platform; y copies the one
    # of those the session has, or its id. With several PRs, o and y ask
    # which first.
    module Browsing
      private

      def open_pr
        session = selected_session
        return notice("no pull request linked — P sets one") unless session&.pr
        return @modal = Dialog::PrPicker.new(:open, session) if session.prs.size > 1
        open_in_browser(session.pr.url, session.pr.short)
      end

      def open_remote
        url = selected_session&.remote_url
        return notice("no claude.ai/code page for this session") unless url
        open_in_browser(url, "claude.ai/code")
      end

      def yank
        session = selected_session
        return notice("nothing to copy") unless session
        return @modal = Dialog::PrPicker.new(:copy, session) if session.prs.size > 1
        copy_to_clipboard(*yank_target(session))
      end

      def pr_picked
        kind, pr = @modal.kind, @modal.choice
        @modal = nil
        (kind == :open) ? open_in_browser(pr.url, pr.short) : copy_to_clipboard(pr.url, pr.short)
      end

      def copy_to_clipboard(text, what)
        in_background do
          @queue << [:notice, @clipboard.call(text) ? "copied #{what}" : "no clipboard tool found"]
        end
      end

      # A link set by hand wins over the scan, as it does once the poll lands.
      def yank_target(session)
        linked = @store.pr_for(session.key)
        return [linked, "#" + linked[%r{/pull/(\d+)}, 1]] if linked
        return [session.pr.url, session.pr.short] if session.pr
        return [session.remote_url, session.remote_url] if session.remote_url
        [session.key, session.key]
      end

      def open_in_browser(url, what)
        opener = RUBY_PLATFORM.include?("darwin") ? "open" : "xdg-open"
        notice("opening #{what}")
        in_background { Subprocess.capture(opener, url) }
      end
    end
  end
end
