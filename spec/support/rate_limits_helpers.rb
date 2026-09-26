# frozen_string_literal: true

require "tmpdir"

# Builds expected windows and a RateLimits over a throwaway rate_limits.json.
module RateLimitsHelpers
  def window(label, percent, resets_at = nil) = ClaudeInbox::RateLimits::Window.new(label, percent, resets_at)

  def with_file(json)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "rate_limits.json")
      File.write(path, json) if json
      yield ClaudeInbox::RateLimits.new(path: path), path
    end
  end
end

RSpec.configure { |config| config.include RateLimitsHelpers, :rate_limits }
