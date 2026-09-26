# frozen_string_literal: true

# The fixture files under spec/fixtures, and a session built from them.
module Fixtures
  DIR = File.expand_path("../fixtures", __dir__)

  def fixture_path(name) = File.join(DIR, name)

  def fixture_sessions = ClaudeInbox::FixtureClient.new(fixture_path("agents.json")).list

  def wait_for(timeout: 2)
    deadline = Time.now + timeout
    sleep 0.01 while !yield && Time.now < deadline
    yield
  end

  def session(**attrs)
    ClaudeInbox::Session.new(
      id: "abc12345", cwd: "/tmp/proj", kind: "background",
      started_at: Time.at(1_789_400_000), state: "working", name: "thing", **attrs
    )
  end
end

PNG = "\x89PNG\r\n\x1A\n#{"\0" * 16}".b

RSpec.configure { |config| config.include Fixtures }
