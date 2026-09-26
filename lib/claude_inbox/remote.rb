# frozen_string_literal: true

module ClaudeInbox
  # Starting sessions from another device. App reaches it only through
  # Remote::Listener.
  module Remote
  end
end

require_relative "remote/listener"
