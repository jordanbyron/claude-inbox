# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "tmpdir"

describe ClaudeInbox::AgentsClient do
  let(:sessions) { fixture_sessions }

  it "parses every documented field from the fixture" do
    _(sessions.size).must_equal 7
    bg = sessions.find { |s| s.id == "823b882f" }
    _(bg).must_be :background?
    _(bg).must_be :actionable?
    _(bg.state).must_equal "done"
    _(bg.status).must_equal "idle"
    _(bg.pid).must_equal 98455
    _(bg.name).must_equal "comma3x led flashing screen unresponsive"
    _(bg.session_id).must_equal "823b882f-171f-4b66-b779-48a245dd21bc"
    _(bg.started_at.to_f).must_be_close_to 1_789_500_667.399, 0.001
    _(bg.project).must_equal "comma3"
  end

  it "treats interactive rows as present but not actionable" do
    s = sessions.find(&:interactive?)
    _(s.id).must_be_nil
    _(s.state).must_be_nil
    _(s).wont_be :actionable?
    _(s.key).must_equal "4a93393d-1c06-57da-9fb8-12f5b1535d95"
    _(s.effective_state).must_equal "working"
    _(s.display_name).must_equal "claude-inbox-38"
  end

  it "names even the default permission mode when asked to, as a remote start does" do
    a = ClaudeInbox::AgentsClient.spawn_args("claude", prompt: "go", permission_mode: "default", explicit_mode: true)
    _(a).must_equal ["claude", "--bg", "--permission-mode", "default", "--", "go"]
    _(ClaudeInbox::AgentsClient.spawn_args("claude", prompt: "go", explicit_mode: true)).must_equal ["claude", "--bg", "--", "go"]
  end

  it "classifies fixture interactive rows as remote when told their pids" do
    c = ClaudeInbox::FixtureClient.new(fixture_path("agents.json"), origins: {57405 => :remote}, bridges: {57405 => "cse_01AB"})
    s = c.list.find(&:interactive?)
    _(s).must_be :remote?
    _(s.remote_url).must_equal "https://claude.ai/code/session_01AB"
    _(s).wont_be :terminal?
    _(sessions.find(&:interactive?)).must_be :terminal?
  end

  it "drops sub-agent rows entirely instead of listing them" do
    c = ClaudeInbox::FixtureClient.new(fixture_path("agents.json"), origins: {57405 => :subagent})
    _(c.list.size).must_equal sessions.size - 1
    _(c.list.any? { |s| s.pid == 57405 }).must_equal false
  end

  it "drops headless rows too" do
    c = ClaudeInbox::FixtureClient.new(fixture_path("agents.json"), origins: {57405 => :headless})
    _(c.list.size).must_equal sessions.size - 1
    _(c.list.any? { |s| s.pid == 57405 }).must_equal false
  end

  describe "reading origins out of the process tree" do
    def origins(rows, parents) = ClaudeInbox::AgentsClient.origins(rows, parents)

    it "knows a terminal by its shell parent" do
      rows = [[100, 200, "claude"]]
      _(origins(rows, {200 => "-zsh"})).must_equal({100 => :terminal})
    end

    it "knows a Remote Control worker by its flag or its parent" do
      _(origins([[100, 200, "claude --sdk-url wss://x"]], {200 => "-zsh"})).must_equal({100 => :remote})
      _(origins([[100, 200, "claude"]], {200 => "claude rc --worker"})).must_equal({100 => :remote})
    end

    it "resumes an adopted conversation under the daemon with Remote Control on" do
      _(ClaudeInbox::AgentsClient.adopt_args("claude", "u1")).must_equal ["claude", "--bg", "--resume", "u1", "--remote-control"]
      _(ClaudeInbox::AgentsClient.transcript_path("/Users/x/.claude/w/p", "u1", home: "/Users/x"))
        .must_equal "/Users/x/.claude/projects/-Users-x--claude-w-p/u1.jsonl"
    end

    it "reads a worker's bridge id off its command line" do
      rows = [[100, 200, "claude --print --sdk-url https://api/cse_01AB --session-id cse_01AB"], [101, 200, "claude"]]
      _(ClaudeInbox::AgentsClient.bridge_ids(rows)).must_equal({100 => "cse_01AB"})
    end

    it "knows a sub-agent by its claude parent" do
      rows = [[100, 200, "claude"]]
      _(origins(rows, {200 => "/Users/x/.local/bin/claude bg-spare --bg-spare /tmp/x.sock"})).must_equal({100 => :subagent})
    end

    # A headless run started from a session's Bash call has that shell for a
    # parent, so the parent test below never sees the claude behind it. This
    # is the tree a real one leaves, `timeout` and all.
    it "knows a headless run by its own flags, whatever spawned it" do
      rows = [[38482, 38480, "claude -p Reply with exactly: OK"]]
      parents = {38480 => "timeout 90 claude -p Reply with exactly: OK"}
      _(origins(rows, parents)).must_equal({38482 => :headless})

      shell_parent = {38480 => "/bin/zsh -c source /Users/x/.claude/shell-snapshots/snapshot-zsh-1.sh"}
      _(origins([[38482, 38480, "claude --input-format stream-json"]], shell_parent)).must_equal({38482 => :headless})
    end

    it "reads the flag out of the arguments, not the program name" do
      _(ClaudeInbox::AgentsClient.headless?("claude")).must_equal false
      _(ClaudeInbox::AgentsClient.headless?("/Users/x/.local/bin/claude -p x")).must_equal true
      _(ClaudeInbox::AgentsClient.headless?("claude-p")).must_equal false
    end
  end

  describe "starting a background session" do
    # Stands in for `claude`: prints an id and records the directory it ran
    # in, or fails when the arguments mention boom.
    before do
      @dir = Dir.mktmpdir
      @bin = File.join(@dir, "claude")
      File.write(@bin, <<~SH)
        #!/bin/sh
        case "$*" in *boom*) echo "no daemon" >&2; echo "see log"; exit 1;; esac
        pwd > #{@dir}/ran_in
        echo "started 1a2b3c4d"
      SH
      File.chmod(0o755, @bin)
    end

    after { FileUtils.rm_rf(@dir) }

    let(:client) { ClaudeInbox::AgentsClient.new(bin: @bin) }

    it "spawns in the given directory and returns the short id" do
      _(client.spawn(prompt: "hi", cwd: @dir)).must_equal "1a2b3c4d"
      _(File.read(File.join(@dir, "ran_in")).strip).must_equal File.realpath(@dir)
    end

    it "says what failed, with everything the CLI printed" do
      e = _ { client.spawn(prompt: "boom", cwd: @dir) }.must_raise ClaudeInbox::AgentsClient::Error
      _(e.message).must_equal "claude --bg failed: no daemon\nsee log"
    end

    it "adopts once the worker is gone and returns the short id" do
      worker = Process.spawn("sleep", "30")
      Process.detach(worker)
      _(client.adopt(session_id: "u1", cwd: @dir, pid: worker)).must_equal "1a2b3c4d"
      _ { Process.kill(0, worker) }.must_raise Errno::ESRCH
    end

    it "names the resume when adopting fails" do
      worker = Process.spawn("sleep", "30")
      Process.detach(worker)
      e = _ { client.adopt(session_id: "boom", cwd: @dir, pid: worker) }.must_raise ClaudeInbox::AgentsClient::Error
      _(e.message).must_equal "claude --bg --resume failed: no daemon\nsee log"
    end
  end

  it "keeps a session whose pid vanished" do
    s = sessions.find { |x| x.id == "b03695b1" }
    _(s).wont_be :alive?
    _(s).must_be :finished?
  end

  it "flags blocked as needing you" do
    _(sessions.find { |x| x.id == "f23c8673" }).must_be :needs_you?
  end
end
