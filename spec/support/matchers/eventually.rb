# frozen_string_literal: true

# Retries `matcher` until it passes or wait_for gives up, for state a
# worker thread lands.
RSpec::Matchers.define :eventually do |matcher|
  match { |actual| wait_for { matcher.matches?(actual) } }

  failure_message { matcher.failure_message }
end
