# frozen_string_literal: true

RSpec.describe ClaudeInbox::Session do
  it "needs only the members it is given" do
    s = described_class.new(id: "abc12345")
    expect(s.id).to eq("abc12345")
    expect(s.kind).to be_nil
    expect(s.prs).to eq([])
    expect(s.pr_urls).to eq([])
    expect(s.line).to be_nil
  end

  it "began when its process started, unless told otherwise" do
    expect(session.created_at).to eq(session.started_at)
    expect(session(created_at: Time.at(1)).created_at).to eq(Time.at(1))
  end

  it "answers [] for prs even when handed nil, as the Struct it replaced did" do
    expect(described_class.new(id: "abc12345", prs: nil).pr).to be_nil
  end

  describe "pr" do
    let(:pr) { ->(number, state, **rest) { ClaudeInbox::PullRequest.new(number: number, state: state, **rest) } }
    let(:old) { pr.call(1, "MERGED", resolved_at: session.created_at.to_i - 60) }

    it "is the troubled one, then an open one, then the first" do
      merged = pr.call(2, "MERGED", resolved_at: session.created_at.to_i + 60)
      open = pr.call(3, "OPEN", health: "CLEAN")
      conflicting = pr.call(4, "OPEN", health: "CONFLICTING")
      failing = pr.call(5, "OPEN", health: "FAILING")
      expect(session(prs: [merged, open, conflicting, failing]).pr).to eq(failing)
      expect(session(prs: [merged, open, conflicting]).pr).to eq(conflicting)
      expect(session(prs: [merged, open]).pr).to eq(open)
      expect(session(prs: [merged, pr.call(6, "CLOSED")]).pr).to eq(merged)
    end

    it "passes over a PR resolved before the session began, unless every PR is" do
      expect(session(prs: [old, pr.call(2, "MERGED", resolved_at: session.created_at.to_i)]).pr.number).to eq(2)
      expect(session(prs: [old, pr.call(2, "CLOSED", resolved_at: 0)]).pr.number).to eq(1)
    end
  end

  describe "prs_by_status" do
    let(:pr) { ->(number, state, **rest) { ClaudeInbox::PullRequest.new(number: number, state: state, **rest) } }

    it "puts open PRs first, then drafts, oldest first; then the resolved, newest first; the mentioned last" do
      later = session.created_at.to_i + 60
      prs = [pr.call(281, "DRAFT", health: "CONFLICTING"), pr.call(279, "DRAFT"),
        pr.call(285, "MERGED", resolved_at: later), pr.call(282, "MERGED", resolved_at: later),
        pr.call(270, "MERGED", resolved_at: session.created_at.to_i - 60), pr.call(290, nil),
        pr.call(286, "OPEN", health: "FAILING"), pr.call(284, "OPEN", health: "CLEAN")]
      expect(session(prs: prs).prs_by_status.map(&:number)).to eq([284, 286, 279, 281, 285, 282, 270, 290])
    end
  end

  # The poller publishes a list and then keeps working on it, so a step that
  # learns something new must not reach into what is already on screen.
  it "answers with a copy from with, leaving the original as it was" do
    original = session(id: "abc12345", state: "working")
    changed = original.with(state: "blocked", remote: true)
    expect(changed.state).to eq("blocked")
    expect(changed).to be_remote
    expect(changed.id).to eq("abc12345")
    expect(original.state).to eq("working")
    expect(original).not_to be_remote
    expect(original).to be_frozen
    expect { original.instance_variable_set(:@state, "x") }.to raise_error(FrozenError)
  end

  it "folds an interactive status into the background vocabulary" do
    s = session(id: nil, kind: "interactive", state: nil, status: "waiting", session_id: "u1")
    expect(s.effective_state).to eq("blocked")
    expect(s).to be_needs_you
    expect(s.key).to eq("u1")
  end
end
