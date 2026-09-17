# frozen_string_literal: true

require_relative "test_helper"

describe ClaudeInbox::AgentsClient do
  let(:sessions) { fixture_sessions }

  it "parses every documented field from the fixture" do
    _(sessions.size).must_equal 7
    bg = sessions.find { |s| s.id == "823b882f" }
    _(bg).must_be :background?
    _(bg).must_be :actionable?
    _(bg.state).must_equal "done"
    _(bg.status).must_equal "idle"
    _(bg.pid).must_equal 98455
    _(bg.name).must_equal "comma3x led flashing screen unresponsive"
    _(bg.session_id).must_equal "823b882f-171f-4b66-b779-48a245dd21bc"
    _(bg.started_at.to_f).must_be_close_to 1_789_500_667.399, 0.001
    _(bg.project).must_equal "comma3"
  end

  it "treats interactive rows as present but not actionable" do
    s = sessions.find(&:interactive?)
    _(s.id).must_be_nil
    _(s.state).must_be_nil
    _(s).wont_be :actionable?
    _(s.display_name).must_equal "claude-inbox-38"
  end

  it "keeps a session whose pid vanished" do
    s = sessions.find { |x| x.id == "b03695b1" }
    _(s).wont_be :alive?
    _(s).must_be :finished?
  end

  it "flags blocked as needing you" do
    _(sessions.find { |x| x.id == "f23c8673" }).must_be :needs_you?
  end
end
