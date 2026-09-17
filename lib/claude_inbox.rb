# frozen_string_literal: true

module ClaudeInbox
  VERSION = "0.1.0"
end

require_relative "claude_inbox/palette"
require_relative "claude_inbox/session"
require_relative "claude_inbox/job_state"
require_relative "claude_inbox/pull_requests"
require_relative "claude_inbox/agents_client"
require_relative "claude_inbox/store"
require_relative "claude_inbox/reaper"
