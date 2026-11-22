# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeInbox::T3::Server do
  let(:dir) { Dir.mktmpdir("t3") }
  let(:token_path) { File.join(dir, "t3-token.json") }
  let(:issued) { [] }
  let(:issuer) do
    path = File.join(dir, "t3")
    File.write(path, "#!/bin/sh\necho \"$@\" >> #{File.join(dir, "issued")}\necho fresh\n")
    File.chmod(0o755, path)
    path
  end
  let(:server) { described_class.new(home: File.join(dir, "home"), bin: issuer, token_path: token_path, timeout: 2) }

  after { FileUtils.remove_entry(dir) }

  it "reads the shell with the token it keeps, naming the protocol it speaks" do
    fake = FakeT3Server.new(File.join(dir, "home"), shell: {"threads" => [{"id" => "t1"}]})
    ClaudeInbox::Records.save(token_path, {"token" => "good"})
    expect(server.shell).to eq("threads" => [{"id" => "t1"}])
    expect(drain(fake.requests)).to eq([["/api/orchestration/shell", "2"]])
    expect(File.exist?(File.join(dir, "issued"))).to be(false)
    fake.stop
  end

  it "issues itself a token through the t3 CLI when it has none, or the server refuses the one it has, and keeps it private" do
    fake = FakeT3Server.new(File.join(dir, "home"), token: "fresh")
    ClaudeInbox::Records.save(token_path, {"token" => "revoked"})
    expect(server.shell).to eq("projects" => [], "threads" => [])
    expect(File.read(File.join(dir, "issued"))).to eq("auth session issue --base-dir #{File.join(dir, "home")} --scope orchestration:read --scope orchestration:operate --label claude-inbox --ttl 30d --token-only\n")
    expect(ClaudeInbox::Records.read(token_path)).to eq("token" => "fresh")
    expect(File.stat(token_path).mode & 0o777).to eq(0o600)
    fake.token = "newer"
    expect(server.shell).to be_nil
    expect(File.read(File.join(dir, "issued")).lines.size).to eq(2)
    fake.stop
  end

  it "answers an RPC over the WebSocket, and says why the server refused one" do
    fake = FakeT3Server.new(File.join(dir, "home"), answers: {"server.getConfig" => {"providers" => []}, "orchestration.dispatchCommand" => RuntimeError.new("No orchestration projection exists for thread nope.")})
    ClaudeInbox::Records.save(token_path, {"token" => "good"})
    expect(server.call("server.getConfig")).to eq("providers" => [])
    expect { server.call!("orchestration.dispatchCommand", type: "thread.delete") }.to raise_error(ClaudeInbox::Harnesses::Error, "No orchestration projection exists for thread nope.")
    expect(drain(fake.requests).map(&:first)).to include("server.getConfig", "orchestration.dispatchCommand")
    fake.stop
  end

  it "answers nil with no server running, and is installed only where T3 keeps its home" do
    expect(server.shell).to be_nil
    expect(server.call("server.getConfig")).to be_nil
    expect { server.call!("server.getConfig") }.to raise_error(ClaudeInbox::Harnesses::Error, "T3 Code is not running")
    expect(server).not_to be_installed
    FileUtils.mkdir_p(File.join(dir, "home"))
    expect(server).to be_installed
  end
end
