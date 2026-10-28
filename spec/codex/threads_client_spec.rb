# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeInbox::Codex::ThreadsClient do
  let(:sessions) { ClaudeInbox::Codex::FixtureClient.new(fixture_path("codex-threads.json")).list }
  let(:state) { ->(status, unread: false) { described_class.state(status, unread: unread) } }

  it "reads each thread as a background session to attach to, stop or delete" do
    blocked, working, done = sessions
    expect(sessions.map(&:harness).uniq).to eq([:codex])
    expect(blocked).to have_attributes(id: "01a18430-c021-7682-b3f0-d8474a3eb287", kind: "background", cwd: "/Users/byron/code/parks_genie",
      name: "Staging migration dry run", started_at: Time.at(1_789_500_100), created_at: Time.at(1_789_500_100),
      last_message_at: Time.at(1_789_500_400), pid: nil, actions: %i[attach stop delete], pr_urls: [])
    expect(blocked).to be_attachable
    expect(blocked.intent).to start_with("Run the migration")
    expect(working.name).to eq("Explain why the flaky spec in spec/poller_spec.rb times out on CI")
    expect([blocked, working, done].map(&:state)).to eq(%w[blocked working done])
    expect(blocked).to have_attributes(branch: "staging-migration", origin_url: "git@github.com:jordanbyron/parks_genie.git")
    expect(done).to have_attributes(branch: nil, origin_url: nil)
  end

  it "reads a status in OSC 7501's words, an unread turn making an idle thread done" do
    expect(state.call({"type" => "active", "activeFlags" => []})).to eq(["working", nil])
    expect(state.call({"type" => "active", "activeFlags" => ["waitingOnApproval"]})).to eq(["blocked", "permission"])
    expect(state.call({"type" => "active", "activeFlags" => ["waitingOnUserInput"]})).to eq(["blocked", "question"])
    expect(state.call({"type" => "systemError"})).to eq(["error", nil])
    expect(state.call({"type" => "idle"})).to eq(["idle", nil])
    expect(state.call({"type" => "idle"}, unread: true)).to eq(["done", nil])
    expect(state.call({"type" => "notLoaded"}, unread: true)).to eq(["done", nil])
    expect(state.call({"type" => "notLoaded"})).to eq(["idle", nil])
  end

  it "says what a blocked thread waits on, and nothing for the rest" do
    expect(sessions.map(&:line)).to eq(["waiting on approval", nil, nil])
    expect(described_class.session("id" => "t", "status" => {"type" => "active", "activeFlags" => ["waitingOnUserInput"]}).line).to eq("waiting on input")
  end

  it "has no name for a thread with neither a name nor a prompt yet" do
    s = described_class.session("id" => "t", "name" => nil, "preview" => "", "status" => {"type" => "idle"})
    expect(s.name).to be_nil
    expect(s.intent).to be_nil
    expect(s.display_name).to eq("t")
  end

  it "lists every kind of thread from the daemon, newest first" do
    Dir.mktmpdir("codex") do |dir|
      fake = FakeCodexDaemon.new(dir, "thread/list" => JSON.parse(File.read(fixture_path("codex-threads.json"))))
      client = described_class.new(daemon: ClaudeInbox::Codex::Daemon.new(socket: fake.path, timeout: 1), clock: -> { Time.at(1_789_600_000) })
      expect(client.list.map(&:state)).to eq(%w[blocked working done])
      expect(drain(fake.requests).last["params"]).to eq("sourceKinds" => %w[cli vscode exec appServer], "sortKey" => "updated_at", "limit" => 100)
      fake.stop
    end
  end

  it "pages on until a thread has been quiet for as long as a reaped Claude session, and leaves those out" do
    Dir.mktmpdir("codex") do |dir|
      now = Time.at(1_789_600_000)
      thread = ->(id, quiet) { {"id" => id, "status" => {"type" => "idle"}, "updatedAt" => now.to_i - quiet} }
      pages = {
        nil => {"data" => [thread.call("t1", 60), thread.call("t2", 3600)], "nextCursor" => "c1"},
        "c1" => {"data" => [thread.call("t3", 86_400), thread.call("t4", ClaudeInbox::Store::REAP_AFTER + 1)], "nextCursor" => "c2"},
        "c2" => {"data" => [thread.call("t5", ClaudeInbox::Store::REAP_AFTER + 2)], "nextCursor" => nil}
      }
      fake = FakeCodexDaemon.new(dir, "thread/list" => ->(params) { pages.fetch(params["cursor"]) })
      client = described_class.new(daemon: ClaudeInbox::Codex::Daemon.new(socket: fake.path, timeout: 1), clock: -> { now })
      expect(client.list.map(&:id)).to eq(%w[t1 t2 t3])
      expect(drain(fake.requests).drop(1).map { |r| r["params"]["cursor"] }).to eq([nil, "c1"])
      fake.stop
    end
  end

  it "lists nothing without a daemon or a fixture" do
    expect(described_class.new(daemon: ClaudeInbox::Codex::Daemon.new(socket: "/nonexistent.sock")).list).to eq([])
    expect(ClaudeInbox::Codex::FixtureClient.new("/nonexistent/codex-threads.json").list).to eq([])
  end

  describe "acting on a thread" do
    let(:dir) { Dir.mktmpdir("codex") }
    let(:thread) { session(harness: :codex, id: "t1", cwd: dir) }
    let(:turns) { {"data" => [{"id" => "turn9", "status" => "inProgress"}]} }
    let(:fake) do
      FakeCodexDaemon.new(dir, "thread/turns/list" => ->(_) { turns }, "turn/interrupt" => {}, "thread/delete" => {},
        "thread/start" => {"thread" => {"id" => "t2"}}, "turn/start" => {"turn" => {"id" => "turn1", "status" => "inProgress"}},
        "model/list" => {"data" => [{"id" => "gpt-6.1-sol"}, {"id" => "secret", "hidden" => true}, {"id" => "gpt-6-luna"}]})
    end
    let(:client) { described_class.new(daemon: ClaudeInbox::Codex::Daemon.new(socket: fake.path, timeout: 1)) }
    let(:sent) { -> { drain(fake.requests).drop(1).map { |r| [r["method"], r["params"]] } } }

    after do
      fake.stop
      FileUtils.remove_entry(dir)
    end

    it "interrupts the turn under way, found from the newest turn" do
      expect(client.stop(thread)).to be(true)
      expect(sent.call).to eq([["thread/turns/list", {"threadId" => "t1", "sortDirection" => "desc", "limit" => 1}],
        ["turn/interrupt", {"threadId" => "t1", "turnId" => "turn9"}]])
    end

    it "has nothing to stop between turns" do
      turns["data"][0]["status"] = "completed"
      expect(client.stop(thread)).to be(false)
      expect(sent.call.map(&:first)).to eq(["thread/turns/list"])
    end

    it "deletes the thread, and says why when the daemon refuses" do
      client.rm(thread)
      expect(sent.call).to eq([["thread/delete", {"threadId" => "t1"}]])
      refusing = FakeCodexDaemon.new(FileUtils.mkdir_p(File.join(dir, "refusing")).first, "thread/delete" => {"error" => {"code" => -32600, "message" => "no rollout found for thread id t1"}})
      expect { described_class.new(daemon: ClaudeInbox::Codex::Daemon.new(socket: refusing.path, timeout: 1)).rm(thread) }
        .to raise_error(ClaudeInbox::Codex::Daemon::Error, /no rollout found/)
      refusing.stop
    end

    it "starts a thread, then its first turn, with the permissions as a policy and a sandbox" do
      expect(client.spawn(prompt: "fix it", cwd: dir, effort: "low", permission_mode: "full-access", images: ["/tmp/a.png"])).to eq("t2")
      expect(sent.call).to eq([
        ["thread/start", {"cwd" => dir, "approvalPolicy" => "never", "sandbox" => "danger-full-access"}],
        ["turn/start", {"threadId" => "t2", "input" => [{"type" => "text", "text" => "fix it"}, {"type" => "localImage", "path" => "/tmp/a.png"}], "effort" => "low"}]
      ])
    end

    it "leaves the model, effort and permissions to Codex's config by default" do
      client.spawn(prompt: "fix it", cwd: dir)
      expect(sent.call.map(&:last)).to eq([{"cwd" => dir}, {"threadId" => "t2", "input" => [{"type" => "text", "text" => "fix it"}]}])
    end

    it "offers the daemon's models, default first and the hidden ones left out, asking once" do
      2.times { expect(client.models).to eq(%w[default gpt-6.1-sol gpt-6-luna]) }
      expect(sent.call.map(&:first)).to eq(["model/list"])
      expect(described_class.new(daemon: ClaudeInbox::Codex::Daemon.new(socket: File.join(dir, "none.sock"))).models).to eq([])
    end

    it "resumes the thread in its own directory, so codex asks no question first" do
      bin = File.join(dir, "codex")
      File.write(bin, "#!/bin/sh\necho \"$PWD $*\" > \"$0.log\"\n")
      File.chmod(0o755, bin)
      expect(described_class.new(bin: bin).attach(thread)).to be(true)
      expect(File.read("#{bin}.log")).to eq("#{File.realpath(dir)} resume t1\n")
    end
  end
end
