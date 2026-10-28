# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeInbox::Codex::Daemon do
  let(:dir) { Dir.mktmpdir("codex") }
  let(:fake) { FakeCodexDaemon.new(dir, "thread/list" => ->(params) { {"data" => [], "echo" => params} }) }
  let(:daemon) { described_class.new(socket: fake.path, timeout: 1) }

  after do
    daemon.close
    fake.stop
    FileUtils.remove_entry(dir)
  end

  it "introduces itself once, then answers each call past the notifications in between" do
    expect(daemon.call("thread/list", limit: 5)).to eq("data" => [], "echo" => {"limit" => 5})
    expect(daemon.call("thread/list", limit: 6)["echo"]).to eq("limit" => 6)
    first, *rest = drain(fake.requests)
    expect(first).to include("method" => "initialize", "params" => {"clientInfo" => {"name" => "claude-inbox", "version" => ClaudeInbox::VERSION}})
    expect(rest.map { |r| r["method"] }).to eq(%w[thread/list thread/list])
    expect(fake.connections).to eq(1)
  end

  it "connects again when the daemon has dropped it since the last call" do
    daemon.call("thread/list")
    fake.drop
    expect(daemon.call("thread/list")).to include("data" => [])
    expect(fake.connections).to eq(2)
  end

  it "answers nil for an error, and keeps the connection" do
    expect(daemon.call("thread/nope")).to be_nil
    expect(daemon.call("thread/list")).to include("data" => [])
    expect(fake.connections).to eq(1)
  end

  it "answers nil with no daemon to ask" do
    expect(described_class.new(socket: File.join(dir, "missing.sock")).call("thread/list")).to be_nil
    expect(described_class.new(bin: File.join(dir, "no-codex")).call("thread/list")).to be_nil
  end
end
