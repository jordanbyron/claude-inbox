# frozen_string_literal: true

require "bundler/setup"
require "stringio"
require "json"
require "tmpdir"
require "fileutils"

# As exe/claude-inbox sets it, so the suite reads files the way the app does
# under any locale.
Encoding.default_external = Encoding::UTF_8

# lib/ resolves ~/.claude and ~/.config/claude-inbox when it loads, so the
# home it sees is an empty one: no example reads your settings, trusted
# directories or inbox state, or writes over them. Set after bundler/setup,
# which still wants the real home to find its config, and in the environment
# Bundler saved too, since that is the one Subprocess hands its children.
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

  # An exit or abort the example didn't expect fails that example; left
  # alone it would end the run there, reporting no failures.
  config.around do |example|
    example.run
  rescue SystemExit => e
    raise "exited with status #{e.status}, which no expectation caught"
  end
end
