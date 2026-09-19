# frozen_string_literal: true

require_relative "job_state"
require_relative "pull_requests"

module ClaudeInbox
  # Puts the list together: the daemon's rows, each background one with its
  # job file attached, each with the pull requests already known about it.
  #
  # The order is the point, and this is the one place it is set: the PR
  # links PullRequests wants are the ones JobState read off the job file, so
  # JobState goes first. Nothing here asks gh. That is `PullRequests#refresh`,
  # a network round trip per open PR, and the poller runs it only once this
  # list has already gone up.
  module Sessions
    module_function

    # => Array<Session>
    def load(client:, jobs_dir:, pull_requests:, overrides:)
      sessions = JobState.enrich(client.list, jobs_dir: jobs_dir)
      pull_requests.enrich(sessions, overrides)
    end
  end
end
