# frozen_string_literal: true

RSpec.describe ClaudeInbox::Harnesses do
  let(:claude) { RecordingClient.new }
  let(:codex) { ClaudeInbox::Codex::FixtureClient.new(fixture_path("codex-threads.json")) }
  let(:harnesses) { described_class.new(claude: claude, codex: codex) }

  it "has each harness's pulse" do
    expect(harnesses.pulse).to eq([claude.pulse, codex.pulse])
    expect(codex.pulse).to be_nil
  end

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

  it "starts a session in the harness it names" do
    allow(codex).to receive(:spawn).and_return("t9")
    expect(harnesses.spawn(harness: :codex, prompt: "hi", cwd: "/tmp")).to eq("t9")
    expect(codex).to have_received(:spawn).with(prompt: "hi", cwd: "/tmp")
    expect(claude.spawns).to be_empty
  end

  it "offers only the harnesses with choices to start with" do
    expect(harnesses.choices.keys).to eq(%i[claude codex])
    allow(codex).to receive(:choices).and_return({})
    expect(harnesses.choices).to eq(claude: ClaudeInbox::Claude::AgentsClient::CHOICES)
  end

  describe "with T3 Code beside them" do
    let(:offered) { {model: %w[default gpt-6-luna], effort: %w[default], permission_mode: %w[default], default: "t3 default"} }
    let(:t3) { instance_double(ClaudeInbox::T3::ThreadsClient, choices: {codex: offered, antigravity: offered}, spawn: "t3-id") }
    let(:harnesses) { described_class.new(claude: claude, codex: codex, t3: t3) }

    it "starts Codex and Antigravity on T3 while it has them ready, saying which harness" do
      expect(harnesses.choices).to include(codex: offered, antigravity: offered)
      expect(harnesses.route(:codex)).to eq(:t3)
      expect(harnesses.route(:claude)).to eq(:claude)
      expect(harnesses.spawn(harness: :antigravity, prompt: "hi", cwd: "/tmp")).to eq("t3-id")
      expect(t3).to have_received(:spawn).with(harness: :antigravity, prompt: "hi", cwd: "/tmp")
    end

    it "starts Codex on its own daemon when T3 has no Codex ready, and refuses Antigravity" do
      allow(t3).to receive(:choices).and_return(antigravity: nil)
      allow(codex).to receive(:spawn).and_return("t9")
      expect(harnesses.choices).to include(codex: codex.choices, antigravity: nil)
      expect(harnesses.route(:codex)).to eq(:codex)
      expect(harnesses.spawn(harness: :codex, prompt: "hi", cwd: "/tmp")).to eq("t9")
      expect { harnesses.spawn(harness: :antigravity, prompt: "hi", cwd: "/tmp") }.to raise_error(ClaudeInbox::Harnesses::Error, /antigravity runs on T3 Code/)
      expect(t3).not_to have_received(:spawn)
    end
  end
end
