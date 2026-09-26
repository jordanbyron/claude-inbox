# frozen_string_literal: true

# Parses a request head from a string for the Http specs. Calls the
# group's `deadline`.
module HttpHelpers
  def head(text) = ClaudeInbox::Remote::Http.read_head(StringIO.new(text.b), deadline: deadline)
end

RSpec.configure { |config| config.include HttpHelpers, :http_head }
