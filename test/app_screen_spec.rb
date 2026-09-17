# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/claude_inbox/app"
require "stringio"

describe ClaudeInbox::App do
  let(:out) { StringIO.new }

  let(:app) do
    ClaudeInbox::App.new(
      client: ClaudeInbox::FixtureClient.new(fixture_path("agents.json")),
      store: ClaudeInbox::Store.new(path: nil),
      pull_requests: ClaudeInbox::PullRequests.new(jobs_dir: fixture_path("jobs"), cache_path: nil, gh: nil),
      out: out, input: StringIO.new, color: false
    )
  end

  # StringIO#string hands back the live buffer, so copy before clearing it.
  def taken = out.string.dup.tap {
    out.truncate(0)
    out.rewind
  }

  it "takes the wheel for the duration of the alt screen and hands it back" do
    app.send(:enter_screen)
    entered = taken
    _(entered).must_include ClaudeInbox::App::ALT_ON
    _(entered).must_include ClaudeInbox::App::WHEEL_KEYS_ON

    app.send(:restore_screen)
    left = taken
    _(left).must_include ClaudeInbox::App::WHEEL_KEYS_OFF
    # The mode belongs to the alt screen, so it has to go first.
    _(left.index(ClaudeInbox::App::WHEEL_KEYS_OFF)).must_be :<, left.index(ClaudeInbox::App::ALT_OFF)
  end
end
