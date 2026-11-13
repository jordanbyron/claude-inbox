# frozen_string_literal: true

require "json"
require "tmpdir"

RSpec.describe ClaudeInbox::Rex do
  let(:calls) { [] }
  let(:existing) { [] }
  let(:clients) do
    [{"client_id" => "client:mac", "info" => {"kind" => "app"}, "session_ids" => ["session:inbox"]},
      {"client_id" => "client:ipad", "info" => {"kind" => "app"}, "session_ids" => ["session:other"]},
      {"client_id" => "client:cli", "info" => {"kind" => "cli"}}]
  end
  let(:ok) { ->(out) { ClaudeInbox::Subprocess::Result.new(out, "", instance_double(Process::Status, success?: true)) } }
  let(:run) do
    lambda do |*argv|
      calls << argv
      case argv[1]
      when "block" then ok[JSON.generate("blocks" => existing)]
      when "client" then ok[JSON.generate("clients" => clients)]
      when "run" then ok[JSON.generate("window_id" => "window:new", "block_ids" => ["block:new"])]
      else ok[""]
      end
    end
  end
  let(:rex) { described_class.new(session: "session:inbox", block: "block:inbox", launcher: "claude-inbox", run: run) }
  let(:dir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(dir) }

  describe ".from_env" do
    it "is nil outside Rex" do
      expect(described_class.from_env({})).to be_nil
      expect(described_class.from_env({"REX_SESSION" => "session:inbox"})).to be_nil
    end

    it "comes back to the pane it was started in, finding the inbox's own ruby" do
      env = {"REX_SESSION" => "session:inbox", "REX_BLOCK" => "block:inbox"}
      expect(described_class.from_env(env).attach_command(session(id: "abc12345", cwd: nil)))
        .to eq(["env", "PATH=#{ClaudeInbox::Subprocess::CHILD_ENV["PATH"]}", "claude-inbox", "attach", "--harness=claude", "--return-to=block:inbox", "abc12345"])
    end
  end

  describe "#open" do
    it "opens a tab that attaches and comes back to the inbox, named after the session" do
      rex.open(session(id: "abc12345", cwd: dir, name: "fix login"))
      expect(calls[1]).to eq(["rex", "run", "--label", "claude-inbox:abc12345", "-c", dir, "--json", "-s", "session:inbox", "--",
        "claude-inbox", "attach", "--harness=claude", "--cwd=#{dir}", "--return-to=block:inbox", "abc12345"])
      expect(calls[2]).to eq(["rex", "window", "rename", "window:new", "fix login", "-s", "session:inbox"])
    end

    it "has the apps showing the inbox switch to the new tab, which the server alone would not make them do" do
      rex.open(session(id: "abc12345", cwd: dir))
      expect(calls.last).to eq(["rex", "-C", "client:mac", "do", "session.select", "session_id=session:inbox", "window_id=window:new"])
      expect(calls.count { |c| c[1] == "-C" }).to eq(1)
    end

    it "brings forward the tab already open for the session" do
      existing << {"block_id" => "block:old", "label" => "claude-inbox:abc12345", "window_id" => "window:old"}
      rex.open(session(id: "abc12345", cwd: dir))
      expect(calls.map { |c| c[1] }).to eq(%w[block focus client -C])
      expect(calls[1]).to eq(["rex", "focus", "block:old", "-s", "session:inbox"])
      expect(calls.last.last).to eq("window_id=window:old")
    end

    it "leaves out a directory that is gone" do
      rex.open(session(id: "abc12345", cwd: File.join(dir, "gone")))
      expect(calls[1]).not_to include("-c")
    end

    it "says why when rex refuses" do
      failed = ClaudeInbox::Subprocess::Result.new("", "no such session\n", instance_double(Process::Status, success?: false))
      refusing = described_class.new(session: "session:gone", block: "block:inbox", launcher: "claude-inbox", run: ->(*) { failed })
      expect { refusing.open(session) }.to raise_error(ClaudeInbox::Rex::Error, "rex: no such session")
    end

    it "passes on the app's refusal, with where to turn Remote Control on" do
      refusal = "Error: Rex.app is not accepting actions. Turn on Remote Control in its Settings under Rex Server.\n"
      refusing = lambda do |*argv|
        next run.call(*argv) unless argv[1] == "-C"
        ClaudeInbox::Subprocess::Result.new("", refusal, instance_double(Process::Status, success?: false))
      end
      app_off = described_class.new(session: "session:inbox", block: "block:inbox", launcher: "claude-inbox", run: refusing)
      expect { app_off.open(session(cwd: dir)) }.to raise_error(ClaudeInbox::Rex::Error,
        "rex: Rex.app is not accepting actions. Turn on Remote Control in its Settings under Rex Server.")
    end
  end

  describe "#show" do
    it "focuses the pane and has the apps show its tab" do
      existing << {"block_id" => "block:inbox", "label" => "shell", "window_id" => "window:inbox"}
      rex.show("block:inbox")
      expect(calls[1]).to eq(["rex", "focus", "block:inbox", "-s", "session:inbox"])
      expect(calls.last.last).to eq("window_id=window:inbox")
    end

    it "says so when the pane is gone" do
      expect { rex.show("block:gone") }.to raise_error(ClaudeInbox::Rex::Error, "rex: no pane block:gone")
    end
  end
end
