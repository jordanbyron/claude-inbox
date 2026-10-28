# frozen_string_literal: true

module ClaudeInbox
  # Puts the list together: the adapter hands back finished sessions, with
  # the PR links its harness scanned, and PullRequests puts what is known
  # about each on top. Nothing here asks gh: that is `PullRequests#refresh`,
  # which the poller runs once this list has gone up.
  module Sessions
    module_function

    def load(client:, pull_requests:, overrides:)
      pull_requests.enrich(client.list, overrides)
    end
  end
end
