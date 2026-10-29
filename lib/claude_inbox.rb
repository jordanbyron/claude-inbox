# frozen_string_literal: true

module ClaudeInbox
  VERSION = "0.14.4"
  CHECKOUT = File.exist?(File.expand_path("../.git", __dir__))
end
