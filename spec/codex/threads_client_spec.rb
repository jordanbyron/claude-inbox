# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeInbox::Codex::ThreadsClient do
  let(:sessions) { ClaudeInbox::Codex::FixtureClient.new(fixture_path("codex-threads.json")).list }
  let(:state) { ->(status, unread: false) { described_class.state(status, unread: unread) } }

  it "reads each thread as a background session Codex can do nothing to from here" do
    blocked, working, done = sessions
    expect(sessions.map(&:harness).uniq).to eq([:codex])
    expect(blocked).to have_attributes(id: "01a18430-c021-7682-b3f0-d8474a3eb287", kind: "background", cwd: "/Users/byron/code/parks_genie",
      name: "Staging migration dry run", started_at: Time.at(1_789_500_100), created_at: Time.at(1_789_500_100),
      last_message_at: Time.at(1_789_500_400), pid: nil, actions: [], pr_urls: [])
    expect(blocked).to be_actionable
    expect(blocked).not_to be_attachable
    expect(blocked.intent).to start_with("Run the migration")
    expect(working.name).to eq("Explain why the flaky spec in spec/poller_spec.rb times out on CI")
    expect([blocked, working, done].map(&:state)).to eq(%w[blocked working done])
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

  it "lists one page of every kind of thread, newest first, from the daemon" do
    Dir.mktmpdir("codex") do |dir|
      fake = FakeCodexDaemon.new(dir, "thread/list" => JSON.parse(File.read(fixture_path("codex-threads.json"))))
      client = described_class.new(daemon: ClaudeInbox::Codex::Daemon.new(socket: fake.path, timeout: 1))
      expect(client.list.map(&:state)).to eq(%w[blocked working done])
      expect(drain(fake.requests).last["params"]).to eq("sourceKinds" => %w[cli vscode exec appServer], "sortKey" => "updated_at", "limit" => 50)
      fake.stop
    end
  end

  it "lists nothing without a daemon or a fixture" do
    expect(described_class.new(daemon: ClaudeInbox::Codex::Daemon.new(socket: "/nonexistent.sock")).list).to eq([])
    expect(ClaudeInbox::Codex::FixtureClient.new("/nonexistent/codex-threads.json").list).to eq([])
  end
end
