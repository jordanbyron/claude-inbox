# frozen_string_literal: true

# Waits for the Logs worker to cache `id`, then compares its lines.
RSpec::Matchers.define :cache_eventually do |id, lines|
  match { |logs| wait_for { logs.cached(id) } == lines }

  failure_message do |logs|
    "expected #{id} to be cached as #{lines.inspect}, got #{logs.cached(id).inspect}"
  end
end
