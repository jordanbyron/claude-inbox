# frozen_string_literal: true

RSpec.describe ClaudeInbox::Harnesses do
  let(:claude) { RecordingClient.new }
  let(:codex) { ClaudeInbox::Codex::FixtureClient.new(fixture_path("codex-threads.json")) }
  let(:harnesses) { described_class.new(claude: claude, codex: codex) }

  it "lists Claude's sessions, then each other harness's" do
    expect(harnesses.list.map(&:key)).to eq(claude.list.map(&:key) + codex.list.map(&:key))
  end

  it "hands an action to the adapter of the session's harness" do
    allow(codex).to receive(:stop).and_call_original
    harnesses.stop(session(id: "abc12345"))
    harnesses.stop(session(harness: :codex, id: "t1"))
    expect(claude.stopped).to eq(["abc12345"])
    expect(codex).to have_received(:stop).with(have_attributes(id: "t1"))
  end

  it "starts sessions with Claude" do
    expect(harnesses.spawn(prompt: "hi", cwd: "/tmp")).to eq("deadbeef")
    expect(claude.spawns).to eq([{prompt: "hi", cwd: "/tmp"}])
  end
end
