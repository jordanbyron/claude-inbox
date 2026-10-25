# frozen_string_literal: true

require "bundler/setup"
require "stringio"
require "json"
require "tmpdir"
require "fileutils"

# As exe/claude-inbox sets it, whatever the locale.
Encoding.default_external = Encoding::UTF_8

# lib/ resolves ~ when it loads, so it must see an empty home: set after
# bundler/setup, which needs the real one, and in the env Subprocess hands on.
home = Dir.mktmpdir("claude-inbox-home")
ENV["HOME"] = Bundler::ORIGINAL_ENV["HOME"] = home
at_exit { FileUtils.remove_entry(home) }

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

  # A stray exit would otherwise end the run reporting no failures.
  config.around do |example|
    example.run
  rescue SystemExit => e
    raise "exited with status #{e.status}, which no expectation caught"
  end
end
