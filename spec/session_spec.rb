# frozen_string_literal: true

RSpec.describe ClaudeInbox::Session do
  it "needs only the members it is given" do
    s = ClaudeInbox::Session.new(id: "abc12345")
    expect(s.id).to eq("abc12345")
    expect(s.kind).to be_nil
    expect(s.prs).to eq([])
    expect(s.job_state).to be_nil
  end

  it "knows where claude.ai/code shows it, from the job file or the worker's own bridge id" do
    expect(session.remote_url).to be_nil
    bg = session(job_state: ClaudeInbox::JobState.new("bridgeSessionId" => "cse_01AB"))
    expect(bg.remote_url).to eq("https://claude.ai/code/session_01AB")
    worker = session(id: nil, kind: "interactive", origin: :remote, bridge_id: "cse_01CD")
    expect(worker.remote_url).to eq("https://claude.ai/code/session_01CD")
  end

  it "has Remote Control when started with the flag, or when a remote server spawned it" do
    expect(session(job_state: ClaudeInbox::JobState.new("bridgeSessionId" => "cse_01AB"))).not_to be_remote_control
    expect(session(job_state: ClaudeInbox::JobState.new("respawnFlags" => ["--remote-control"]))).to be_remote_control
    expect(session(id: nil, kind: "interactive", origin: :remote)).to be_remote_control
  end

  it "answers [] for prs even when handed nil, as the Struct it replaced did" do
    expect(ClaudeInbox::Session.new(id: "abc12345", prs: nil).pr).to be_nil
  end

  # The poller publishes a list and then keeps working on it, so a step that
  # learns something new must not reach into what is already on screen.
  it "answers with a copy from with, leaving the original as it was" do
    original = session(id: "abc12345", state: "working")
    changed = original.with(state: "blocked", origin: :remote)
    expect(changed.state).to eq("blocked")
    expect(changed.origin).to eq(:remote)
    expect(changed.id).to eq("abc12345")
    expect(original.state).to eq("working")
    expect(original.origin).to be_nil
    expect(original).to be_frozen
    expect { original.instance_variable_set(:@state, "x") }.to raise_error(FrozenError)
  end

  it "folds an interactive status into the background vocabulary" do
    s = session(id: nil, kind: "interactive", state: nil, status: "waiting", session_id: "u1")
    expect(s.effective_state).to eq("blocked")
    expect(s).to be_needs_you
    expect(s.key).to eq("u1")
  end

  describe "summary" do
    let(:job) do
      ClaudeInbox::JobState.new("detail" => "watching CI",
        "needs" => "confirm: merge?", "output" => {"result" => "CI green, PR #7 up"})
    end

    it "is what the session needs while blocked, what it produced once done, else its status line" do
      expect(session(state: "blocked", job_state: job).summary).to eq("confirm: merge?")
      expect(session(state: "done", job_state: job).summary).to eq("CI green, PR #7 up")
      expect(session(state: "working", job_state: job).summary).to eq("watching CI")
    end

    it "falls back to the status line when the state-specific line is missing" do
      job = ClaudeInbox::JobState.new("detail" => "watching CI")
      expect(session(state: "blocked", job_state: job).summary).to eq("watching CI")
      expect(session(state: "done", job_state: job).summary).to eq("watching CI")
    end

    it "is nil without a job file or before the session has said anything" do
      expect(session(job_state: nil).summary).to be_nil
      expect(session(job_state: ClaudeInbox::JobState.new({})).summary).to be_nil
      expect(session(job_state: ClaudeInbox::JobState.new("detail" => "  ")).summary).to be_nil
    end

    it "flattens the line onto one row" do
      job = ClaudeInbox::JobState.new("detail" => "step one\n  step two")
      expect(session(job_state: job).summary).to eq("step one step two")
    end
  end

  describe "intent" do
    it "is the prompt the session was started with" do
      job = ClaudeInbox::JobState.new("intent" => "Look into the TIAA gateway 403s")
      expect(session(job_state: job).intent).to eq("Look into the TIAA gateway 403s")
    end

    it "is nil without a job file, as an interactive session has none" do
      expect(session(job_state: nil).intent).to be_nil
      expect(session(job_state: ClaudeInbox::JobState.new({})).intent).to be_nil
    end
  end
end
