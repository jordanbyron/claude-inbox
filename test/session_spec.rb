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

  it "answers [] for prs even when handed nil, as the Struct it replaced did" do
    _(ClaudeInbox::Session.new(id: "abc12345", prs: nil).pr).must_be_nil
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

  describe "summary" do
    let(:job) do
      ClaudeInbox::JobState.new("detail" => "watching CI",
        "needs" => "confirm: merge?", "output" => {"result" => "CI green, PR #7 up"})
    end

    it "is what the session needs while blocked, what it produced once done, else its status line" do
      _(session(state: "blocked", job_state: job).summary).must_equal "confirm: merge?"
      _(session(state: "done", job_state: job).summary).must_equal "CI green, PR #7 up"
      _(session(state: "working", job_state: job).summary).must_equal "watching CI"
    end

    it "falls back to the status line when the state-specific line is missing" do
      job = ClaudeInbox::JobState.new("detail" => "watching CI")
      _(session(state: "blocked", job_state: job).summary).must_equal "watching CI"
      _(session(state: "done", job_state: job).summary).must_equal "watching CI"
    end

    it "is nil without a job file or before the session has said anything" do
      _(session(job_state: nil).summary).must_be_nil
      _(session(job_state: ClaudeInbox::JobState.new({})).summary).must_be_nil
      _(session(job_state: ClaudeInbox::JobState.new("detail" => "  ")).summary).must_be_nil
    end

    it "flattens the line onto one row" do
      job = ClaudeInbox::JobState.new("detail" => "step one\n  step two")
      _(session(job_state: job).summary).must_equal "step one step two"
    end
  end

  describe "intent" do
    it "is the prompt the session was started with" do
      job = ClaudeInbox::JobState.new("intent" => "Look into the TIAA gateway 403s")
      _(session(job_state: job).intent).must_equal "Look into the TIAA gateway 403s"
    end

    it "is nil without a job file, as an interactive session has none" do
      _(session(job_state: nil).intent).must_be_nil
      _(session(job_state: ClaudeInbox::JobState.new({})).intent).must_be_nil
    end
  end
end
