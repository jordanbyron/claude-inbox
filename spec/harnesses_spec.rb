# frozen_string_literal: true

RSpec.describe ClaudeInbox::Harnesses do
  let(:claude) { RecordingClient.new }
  let(:codex) { ClaudeInbox::Codex::FixtureClient.new(fixture_path("codex-threads.json")) }
  let(:harnesses) { described_class.new(claude, [codex]) }

  it "lists Claude's sessions, then each other harness's" do
    expect(harnesses.list.map(&:key)).to eq(claude.list.map(&:key) + codex.list.map(&:key))
  end

  it "hands every action to Claude" do
    harnesses.stop("abc12345")
    expect(claude.stopped).to eq(["abc12345"])
  end
end
