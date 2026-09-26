# frozen_string_literal: true

require "bundler/setup"
require "stringio"
require "json"
require_relative "../lib/claude_inbox"
Dir[File.expand_path("../lib/claude_inbox/**/*.rb", __dir__)].sort.each { |f| require f }
Dir[File.expand_path("support/**/*.rb", __dir__)].sort.each { |f| require f }

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.mock_with(:rspec) { |m| m.verify_partial_doubles = true }
  config.define_derived_metadata { |metadata| metadata[:aggregate_failures] = true }
  config.order = :random
  Kernel.srand config.seed
end
