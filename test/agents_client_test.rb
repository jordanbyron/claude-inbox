# frozen_string_literal: true

require_relative "test_helper"

class AgentsClientTest < Minitest::Test
  include Fixtures

  def test_parses_fixture_fields
    sessions = fixture_sessions
    assert_equal 7, sessions.size

    bg = sessions.find { |s| s.id == "823b882f" }
    assert bg.background?
    assert bg.actionable?
    assert_equal "done", bg.state
    assert_equal "idle", bg.status
    assert_equal 98455, bg.pid
    assert_equal "comma3x led flashing screen unresponsive", bg.name
    assert_equal "823b882f-171f-4b66-b779-48a245dd21bc", bg.session_id
    assert_in_delta 1_789_500_667.399, bg.started_at.to_f, 0.001
    assert_equal "comma3", bg.project
  end

  def test_interactive_rows_have_no_id_and_are_not_actionable
    s = fixture_sessions.find(&:interactive?)
    assert_nil s.id
    assert_nil s.state
    refute s.actionable?
    assert_equal "claude-inbox-38", s.display_name
  end

  def test_missing_pid_is_not_alive_but_still_present
    s = fixture_sessions.find { |x| x.id == "b03695b1" }
    refute s.alive?
    assert s.finished?
  end

  def test_blocked_needs_you
    s = fixture_sessions.find { |x| x.id == "f23c8673" }
    assert s.needs_you?
  end
end
