# frozen_string_literal: true

module ClaudeInbox
  class App
    # o opens the selected session's pull request and w its claude.ai/code
    # page, through whatever opens URLs on this platform.
    module Browsing
      private

      def open_pr
        pr = selected_session&.pr
        return notice("no pull request linked — P sets one") unless pr
        open_in_browser(pr.url, pr.short)
      end

      def open_remote
        url = selected_session&.remote_url
        return notice("no claude.ai/code page for this session") unless url
        open_in_browser(url, "claude.ai/code")
      end

      def open_in_browser(url, what)
        opener = RUBY_PLATFORM.include?("darwin") ? "open" : "xdg-open"
        notice("opening #{what}")
        in_background { Subprocess.capture(opener, url) }
      end
    end
  end
end
