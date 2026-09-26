# frozen_string_literal: true

require_relative "job_state"

module ClaudeInbox
  # Puts the list together. JobState goes before PullRequests because the PR
  # links it wants are read off the job file. Nothing here asks gh: that is
  # `PullRequests#refresh`, which the poller runs once this list has gone up.
  module Sessions
    module_function

    def load(client:, pull_requests:, overrides:)
      sessions = JobState.enrich(client.list, jobs_dir: client.jobs_dir)
      pull_requests.enrich(sessions, overrides)
    end
  end
end
