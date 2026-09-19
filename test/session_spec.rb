# frozen_string_literal: true

require_relative "test_helper"

describe ClaudeInbox::Session do
  it "needs only the members it is given" do
    s = ClaudeInbox::Session.new(id: "abc12345")
    _(s.id).must_equal "abc12345"
    _(s.kind).must_be_nil
    _(s.prs).must_equal []
    _(s.job_state).must_be_nil
  end

  # The poller publishes a list and then keeps working on it, so a step that
  # learns something new must not reach into what is already on screen.
  it "answers with a copy from with, leaving the original as it was" do
    original = session(id: "abc12345", state: "working")
    changed = original.with(state: "blocked", origin: :remote)
    _(changed.state).must_equal "blocked"
    _(changed.origin).must_equal :remote
    _(changed.id).must_equal "abc12345"
    _(original.state).must_equal "working"
    _(original.origin).must_be_nil
    _(original).must_be :frozen?
    _ { original.instance_variable_set(:@state, "x") }.must_raise FrozenError
  end

  it "folds an interactive status into the background vocabulary" do
    s = session(id: nil, kind: "interactive", state: nil, status: "waiting", session_id: "u1")
    _(s.effective_state).must_equal "blocked"
    _(s).must_be :needs_you?
    _(s.key).must_equal "u1"
  end
end
