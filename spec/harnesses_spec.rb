# frozen_string_literal: true

RSpec.describe ClaudeInbox::Harnesses do
  let(:claude) { RecordingClient.new }
  let(:codex) { ClaudeInbox::Codex::FixtureClient.new(fixture_path("codex-threads.json")) }
  let(:antigravity) { ClaudeInbox::Antigravity::FixtureClient.new(fixture_path("antigravity-conversations.json")) }
  let(:harnesses) { described_class.new(claude: claude, codex: codex, antigravity: antigravity) }

  it "has each harness's pulse" do
    expect(harnesses.pulse).to eq([claude.pulse, codex.pulse, antigravity.pulse])
    expect(codex.pulse).to be_nil
    expect(antigravity.pulse).to be_nil
  end

  it "lists Claude's sessions, then each other harness's" do
    expect(harnesses.list.map(&:key)).to eq(claude.list.map(&:key) + codex.list.map(&:key) + antigravity.list.map(&:key))
  end

  it "hands an action to the adapter of the session's harness" do
    allow(codex).to receive(:stop).and_call_original
    allow(antigravity).to receive(:stop).and_call_original
    harnesses.stop(session(id: "abc12345"))
    harnesses.stop(session(harness: :codex, id: "t1"))
    harnesses.stop(session(harness: :antigravity, id: "a1"))
    expect(claude.stopped).to eq(["abc12345"])
    expect(codex).to have_received(:stop).with(have_attributes(id: "t1"))
    expect(antigravity).to have_received(:stop).with(have_attributes(id: "a1"))
  end

  it "starts sessions with Claude" do
    expect(harnesses.spawn(prompt: "hi", cwd: "/tmp")).to eq("deadbeef")
    expect(claude.spawns).to eq([{prompt: "hi", cwd: "/tmp"}])
  end

  it "starts a session in the harness it names" do
    allow(codex).to receive(:spawn).and_return("t9")
    allow(antigravity).to receive(:spawn).and_return("a9")
    expect(harnesses.spawn(harness: :codex, prompt: "hi", cwd: "/tmp")).to eq("t9")
    expect(codex).to have_received(:spawn).with(prompt: "hi", cwd: "/tmp")
    expect(harnesses.spawn(harness: :antigravity, prompt: "hi", cwd: "/tmp")).to eq("a9")
    expect(antigravity).to have_received(:spawn).with(prompt: "hi", cwd: "/tmp")
    expect(claude.spawns).to be_empty
  end

  it "offers only the harnesses with choices to start with" do
    expect(harnesses.choices.keys).to eq(%i[claude codex antigravity])
    allow(codex).to receive(:choices).and_return({})
    allow(antigravity).to receive(:choices).and_return({})
    expect(harnesses.choices).to eq(claude: ClaudeInbox::Claude::AgentsClient::CHOICES)
  end
end
