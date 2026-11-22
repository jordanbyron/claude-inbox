# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeInbox::T3::ThreadsClient do
  let(:shell) { JSON.parse(File.read(fixture_path("t3-shell.json"))) }
  let(:sessions) { ClaudeInbox::T3::FixtureClient.new(fixture_path("t3-shell.json")).list }
  let(:config) do
    {"providers" => [
      {"instanceId" => "codex", "driver" => "codex", "enabled" => true, "status" => "ready", "models" => []},
      {"instanceId" => "work-gemini", "driver" => "antigravity", "enabled" => true, "status" => "ready", "models" => []}
    ]}
  end
  let(:server) { instance_double(ClaudeInbox::T3::Server, shell: shell, call: config, installed?: true) }
  let(:clock) { -> { Time.utc(2026, 9, 15, 20) } }
  let(:client) { described_class.new(server: server, clock: clock) }

  it "reads each thread as a background session under T3, shown as its provider" do
    running, approval, question, _, _ = sessions
    expect(sessions.map(&:harness).uniq).to eq([:t3])
    expect(sessions.map(&:provider)).to eq(%i[codex antigravity codex codex antigravity])
    expect(running).to have_attributes(id: "6f1c2a40-0d1e-4b7a-9c55-1a2b3c4d5e60", kind: "background", name: "Rename the reservations table",
      cwd: "/Users/byron/.t3/worktrees/parks_genie/rename-reservations", branch: "t3/rename-reservations",
      origin_url: "git@github.com:jordanbyron/parks_genie.git", pr_urls: ["https://github.com/jordanbyron/parks_genie/pull/412"],
      started_at: Time.utc(2026, 9, 15, 19, 21, 40), last_message_at: Time.utc(2026, 9, 15, 19, 30), actions: %i[attach stop delete])
    expect(running.harness_name).to eq(:codex)
    expect(approval).to have_attributes(cwd: "/Users/byron/code/parks_genie", branch: nil)
    expect(question).to have_attributes(cwd: "/Users/byron/code/claude-inbox", origin_url: nil)
    expect(sessions.map(&:state)).to eq(%w[working blocked blocked error done])
    expect(sessions.map(&:line)).to eq([nil, "waiting on approval", "waiting on input", "The provider session exited unexpectedly.", nil])
  end

  it "leaves out imported threads, which their own harness lists, and sub-agents" do
    expect(shell["threads"].map { |t| t["id"] }).to include(start_with("import:"), "be6b7f95-5263-4a0f-b1aa-6f708192a3b5")
    expect(sessions.map(&:id)).not_to include(start_with("import:"), "be6b7f95-5263-4a0f-b1aa-6f708192a3b5")
  end

  it "reads a thread's state from its status and what it waits on" do
    state = ->(**t) { described_class.state(t.transform_keys(&:to_s)) }
    expect(state.call(status: "idle")).to eq(["idle"])
    expect(state.call(status: "interrupted")).to eq(["idle"])
    expect(state.call(status: "completed")).to eq(["done"])
    expect(state.call(status: "failed")).to eq(["error"])
    %w[preparing queued starting running waiting].each { |s| expect(state.call(status: s)).to eq(["working"]) }
    expect(state.call(status: "idle", activeRunId: "run:1")).to eq(["working"])
    expect(state.call(status: "waiting", pendingRuntimeRequest: {"kind" => "file-change"})).to eq(["blocked", "permission"])
    expect(state.call(status: "waiting", pendingRuntimeRequest: {"kind" => "user_input", "blocking" => true})).to eq(["blocked", "question"])
    expect(state.call(status: "running", pendingRuntimeRequest: {"kind" => "user_input", "blocking" => false})).to eq(["working"])
  end

  it "names the provider by its driver, so a renamed instance still shows as what it runs" do
    shell["threads"][1]["providerInstanceId"] = "work-gemini"
    client.list
    expect(client.list.map(&:provider)).to eq(%i[codex antigravity codex codex antigravity])
    expect(server).to have_received(:call).with("server.getConfig").once
  end

  it "lists nothing while T3 is down, and leaves out threads quiet past the reaper's horizon" do
    allow(server).to receive(:shell).and_return(nil)
    expect(client.list).to eq([])
    allow(server).to receive(:shell).and_return(shell)
    late = described_class.new(server: server, clock: -> { Time.utc(2026, 9, 15, 19, 25) + ClaudeInbox::Store::REAP_AFTER })
    expect(late.list.map(&:name)).to eq(["Rename the reservations table", "Check the park hours scraper", "Pick a cache for the forecast"])
    expect(ClaudeInbox::T3::FixtureClient.new("/nonexistent/t3-shell.json").list).to eq([])
  end

  it "says so when tria will not start, and counts that a failed attach" do
    out = StringIO.new
    tria = described_class.new(server: server, tria: "/nonexistent/tria", out: out)
    expect(tria.attach(session(harness: :t3, id: "t1", cwd: nil))).to be(false)
    expect(out.string).to eq("/nonexistent/tria would not start\n")
  end

  describe "acting on a thread over the server" do
    let(:dir) { Dir.mktmpdir("t3") }
    let(:fake) { FakeT3Server.new(File.join(dir, "home"), shell: shell, answers: {"orchestration.dispatchCommand" => {"sequence" => 1}}) }
    let(:live) { ClaudeInbox::T3::Server.new(home: fake.home, token_path: File.join(dir, "token.json"), timeout: 2) }
    let(:client) { described_class.new(server: live, clock: clock) }
    let(:commands) { -> { drain(fake.requests).filter_map { |tag, body| body if tag == "orchestration.dispatchCommand" } } }

    before { ClaudeInbox::Records.save(File.join(dir, "token.json"), {"token" => "good"}) }

    after do
      fake.stop
      FileUtils.remove_entry(dir)
    end

    it "interrupts the run under way, and says when there is none" do
      running, approval, = ClaudeInbox::T3::FixtureClient.new(fixture_path("t3-shell.json")).list
      expect(client.stop(running)).to be(true)
      expect(commands.call).to contain_exactly(include("type" => "run.interrupt", "threadId" => running.id, "runId" => "run:1", "commandId" => match(/\A\h{8}-/)))
      shell["threads"][1]["activeRunId"] = nil
      fake.shell = shell
      expect(client.stop(approval)).to be(false)
      expect(commands.call).to be_empty
    end

    it "deletes a thread" do
      client.rm(session(harness: :t3, id: "ad5a6e84"))
      expect(commands.call).to contain_exactly(include("type" => "thread.delete", "threadId" => "ad5a6e84"))
    end
  end
end
