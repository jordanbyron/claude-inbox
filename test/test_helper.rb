# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"
require_relative "../lib/claude_inbox"

module Fixtures
  DIR = File.expand_path("fixtures", __dir__)

  def fixture_path(name) = File.join(DIR, name)

  def fixture_sessions = ClaudeInbox::FixtureClient.new(fixture_path("agents.json")).list

  def session(**attrs)
    ClaudeInbox::Session.new(
      id: "abc12345", cwd: "/tmp/proj", kind: "background",
      started_at: Time.at(1_789_400_000), state: "working", name: "thing", **attrs
    )
  end
end
