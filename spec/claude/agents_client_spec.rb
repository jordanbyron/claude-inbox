# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe ClaudeInbox::Claude::AgentsClient do
  let(:sessions) { ClaudeInbox::Claude::FixtureClient.new(fixture_path("agents.json")).list }

  it "parses every documented field from the fixture" do
    expect(sessions.size).to eq(7)
    bg = sessions.find { |s| s.id == "823b882f" }
    expect(bg).to be_background
    expect(bg).to be_actionable
    expect(bg.state).to eq("done")
    expect(bg.status).to eq("idle")
    expect(bg.pid).to eq(98455)
    expect(bg.name).to eq("comma3x led flashing screen unresponsive")
    expect(bg.session_id).to eq("823b882f-171f-4b66-b779-48a245dd21bc")
    expect(bg.started_at.to_f).to be_within(0.001).of(1_789_500_667.399)
    expect(bg.project).to eq("comma3")
  end

  it "treats interactive rows as present but not actionable" do
    s = sessions.find(&:interactive?)
    expect(s.id).to be_nil
    expect(s.state).to be_nil
    expect(s).not_to be_actionable
    expect(s.key).to eq("4a93393d-1c06-57da-9fb8-12f5b1535d95")
    expect(s.effective_state).to eq("working")
    expect(s.display_name).to eq("claude-inbox-38")
  end

  it "names the default permission mode when given it, as a remote start does" do
    a = described_class.spawn_args("claude", prompt: "go", permission_mode: "default")
    expect(a).to eq(["claude", "--bg", "--permission-mode", "default", "--", "go"])
  end

  it "classifies fixture interactive rows as remote when told their pids" do
    c = ClaudeInbox::Claude::FixtureClient.new(
      fixture_path("agents.json"),
      origins: {57405 => :remote},
      bridges: {57405 => "cse_01AB"}
    )
    s = c.list.find(&:interactive?)
    expect(s).to be_remote
    expect(s.remote_url).to eq("https://claude.ai/code/session_01AB")
    expect(s).not_to be_terminal
    expect(sessions.find(&:interactive?)).to be_terminal
  end

  it "drops sub-agent rows entirely instead of listing them" do
    c = ClaudeInbox::Claude::FixtureClient.new(fixture_path("agents.json"), origins: {57405 => :subagent})
    expect(c.list.size).to eq(sessions.size - 1)
    expect(c.list.any? { |s| s.pid == 57405 }).to be(false)
  end

  it "drops headless rows too" do
    c = ClaudeInbox::Claude::FixtureClient.new(fixture_path("agents.json"), origins: {57405 => :headless})
    expect(c.list.size).to eq(sessions.size - 1)
    expect(c.list.any? { |s| s.pid == 57405 }).to be(false)
  end

  it "reads the job file of a background session only" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "jobs", "aaa11111"))
      File.write(File.join(dir, "jobs", "aaa11111", "state.json"),
        JSON.generate("tempo" => "idle", "inFlight" => {"tasks" => 1}, "fan" => [{"kind" => "shell"}]))
      File.write(File.join(dir, "agents.json"), JSON.generate([
        {"id" => "aaa11111", "kind" => "background", "state" => "working"},
        {"kind" => "interactive", "status" => "busy", "sessionId" => "u1", "pid" => 1}
      ]))
      bg, term = ClaudeInbox::Claude::FixtureClient.new(File.join(dir, "agents.json")).list
      expect(bg.in_flight).to eq("1 shell")
      expect(bg).to be_waiting_on_work
      expect(term.in_flight).to be_nil
      expect(term).not_to be_waiting_on_work
    end
  end

  describe "a row of the JSON as a session" do
    let(:row) { {"id" => "abc12345", "kind" => "background", "state" => "working"} }

    it "reads the daemon's states in OSC 7501's words" do
      states = %w[working blocked done failed stopped].map { |state| described_class.session(row.merge("state" => state)).state }
      expect(states).to eq(%w[working blocked done error idle])
      expect(described_class.session({"kind" => "interactive", "status" => "busy"}).state).to be_nil
      expect(described_class.session(row).harness).to eq(:claude)
    end

    it "knows where claude.ai/code shows it, from the job file or the worker's own bridge id" do
      expect(described_class.session(row).remote_url).to be_nil
      bg = described_class.session(row, job: ClaudeInbox::Claude::JobState.new("bridgeSessionId" => "cse_01AB"))
      expect(bg.remote_url).to eq("https://claude.ai/code/session_01AB")
      worker = described_class.session({"kind" => "interactive"}, origin: :remote, bridge: "cse_01CD")
      expect(worker.remote_url).to eq("https://claude.ai/code/session_01CD")
    end

    it "has Remote Control when started with the flag, or when a remote server spawned it" do
      expect(described_class.session(row, job: ClaudeInbox::Claude::JobState.new("bridgeSessionId" => "cse_01AB"))).not_to be_remote_control
      expect(described_class.session(row, job: ClaudeInbox::Claude::JobState.new("respawnFlags" => ["--remote-control"]))).to be_remote_control
      expect(described_class.session({"kind" => "interactive"}, origin: :remote)).to be_remote_control
    end

    describe "its line" do
      let(:line) { ->(state, job) { described_class.session(row.merge("state" => state), job: job).line } }
      let(:job) do
        ClaudeInbox::Claude::JobState.new("detail" => "watching CI",
          "needs" => "confirm: merge?", "output" => {"result" => "CI green, PR #7 up"})
      end

      it "is what the session needs while blocked, what it produced once done, else its status line" do
        expect(line.call("blocked", job)).to eq("confirm: merge?")
        expect(line.call("done", job)).to eq("CI green, PR #7 up")
        expect(line.call("working", job)).to eq("watching CI")
      end

      it "falls back to the status line when the state-specific line is missing" do
        job = ClaudeInbox::Claude::JobState.new("detail" => "watching CI")
        expect(line.call("blocked", job)).to eq("watching CI")
        expect(line.call("done", job)).to eq("watching CI")
      end

      it "is nil without a job file or before the session has said anything" do
        expect(line.call("working", nil)).to be_nil
        expect(line.call("working", ClaudeInbox::Claude::JobState.new({}))).to be_nil
        expect(line.call("working", ClaudeInbox::Claude::JobState.new("detail" => "  "))).to be_nil
      end

      it "flattens the line onto one row" do
        expect(line.call("working", ClaudeInbox::Claude::JobState.new("detail" => "step one\n  step two"))).to eq("step one step two")
      end
    end

    describe "its intent" do
      it "is the prompt the session was started with" do
        job = ClaudeInbox::Claude::JobState.new("intent" => "Look into the TIAA gateway 403s")
        expect(described_class.session(row, job: job).intent).to eq("Look into the TIAA gateway 403s")
      end

      it "is nil without a job file, as an interactive session has none" do
        expect(described_class.session(row).intent).to be_nil
        expect(described_class.session(row, job: ClaudeInbox::Claude::JobState.new({})).intent).to be_nil
      end
    end
  end

  describe "reading origins out of the process tree" do
    it "knows a terminal by its shell parent" do
      rows = [[100, 200, "claude"]]
      expect(described_class.origins(rows, {200 => "-zsh"})).to eq({100 => :terminal})
    end

    it "knows a Remote Control worker by its flag or its parent" do
      expect(described_class.origins([[100, 200, "claude --sdk-url wss://x"]], {200 => "-zsh"})).to eq({100 => :remote})
      expect(described_class.origins([[100, 200, "claude"]], {200 => "claude rc --worker"})).to eq({100 => :remote})
    end

    it "resumes an adopted conversation under the daemon with Remote Control on" do
      expect(described_class.adopt_args("claude", "u1")).to eq(["claude", "--bg", "--resume", "u1", "--remote-control"])
      expect(described_class.transcript_path("/Users/x/.claude/w/p", "u1", home: "/Users/x"))
        .to eq("/Users/x/.claude/projects/-Users-x--claude-w-p/u1.jsonl")
    end

    it "reads a worker's bridge id off its command line" do
      rows = [[100, 200, "claude --print --sdk-url https://api/cse_01AB --session-id cse_01AB"], [101, 200, "claude"]]
      expect(described_class.bridge_ids(rows)).to eq({100 => "cse_01AB"})
    end

    it "knows a sub-agent by its claude parent" do
      rows = [[100, 200, "claude"]]
      expect(described_class.origins(rows, {200 => "/Users/x/.local/bin/claude bg-spare --bg-spare /tmp/x.sock"})).to eq({100 => :subagent})
    end

    # A headless run started from a session's Bash call has that shell for a
    # parent, so the parent test below never sees the claude behind it. This
    # is the tree a real one leaves, `timeout` and all.
    it "knows a headless run by its own flags, whatever spawned it" do
      rows = [[38482, 38480, "claude -p Reply with exactly: OK"]]
      parents = {38480 => "timeout 90 claude -p Reply with exactly: OK"}
      expect(described_class.origins(rows, parents)).to eq({38482 => :headless})

      shell_parent = {38480 => "/bin/zsh -c source /Users/x/.claude/shell-snapshots/snapshot-zsh-1.sh"}
      expect(described_class.origins([[38482, 38480, "claude --input-format stream-json"]], shell_parent)).to eq({38482 => :headless})
    end

    it "reads the flag out of the arguments, not the program name" do
      expect(described_class.headless?("claude")).to be(false)
      expect(described_class.headless?("/Users/x/.local/bin/claude -p x")).to be(true)
      expect(described_class.headless?("claude-p")).to be(false)
    end
  end

  describe "starting a background session" do
    # Stands in for `claude`: prints an id and records the directory it ran
    # in, or fails when the arguments mention boom.
    let(:dir) { Dir.mktmpdir }
    let(:bin) { File.join(dir, "claude") }

    before do
      File.write(bin, <<~SH)
        #!/bin/sh
        case "$*" in *boom*) echo "no daemon" >&2; echo "see log"; exit 1;; esac
        pwd > #{dir}/ran_in
        echo "started 1a2b3c4d"
      SH
      File.chmod(0o755, bin)
    end

    after { FileUtils.rm_rf(dir) }

    let(:client) { described_class.new(bin: bin) }

    it "spawns in the given directory and returns the short id" do
      expect(client.spawn(prompt: "hi", cwd: dir)).to eq("1a2b3c4d")
      expect(File.read(File.join(dir, "ran_in")).strip).to eq(File.realpath(dir))
    end

    it "gives the new session its color through the job file, as /color would" do
      FileUtils.mkdir_p(File.join(dir, "1a2b3c4d"))
      File.write(File.join(dir, "1a2b3c4d", "state.json"), "{}")
      described_class.new(bin: bin, jobs_dir: dir).spawn(prompt: "hi", cwd: dir, color: "cyan")
      expect(ClaudeInbox::Claude::JobState.read("1a2b3c4d", jobs_dir: dir).color).to eq("cyan")
    end

    it "says what failed, with everything the CLI printed" do
      expect { client.spawn(prompt: "boom", cwd: dir) }.to raise_error(described_class::Error) { |e|
        expect(e.message).to eq("claude --bg failed: no daemon\nsee log")
      }
    end

    it "adopts once the worker is gone and returns the short id" do
      worker = Process.spawn("sleep", "30")
      Process.detach(worker)
      expect(client.adopt(session_id: "u1", cwd: dir, pid: worker)).to eq("1a2b3c4d")
      expect { Process.kill(0, worker) }.to raise_error(Errno::ESRCH)
    end

    it "names the resume when adopting fails" do
      worker = Process.spawn("sleep", "30")
      Process.detach(worker)
      expect { client.adopt(session_id: "boom", cwd: dir, pid: worker) }.to raise_error(described_class::Error) { |e|
        expect(e.message).to eq("claude --bg --resume failed: no daemon\nsee log")
      }
    end
  end

  it "keeps a session whose pid vanished" do
    s = sessions.find { |x| x.id == "b03695b1" }
    expect(s).not_to be_alive
    expect(s).to be_finished
  end

  it "flags blocked as needing you" do
    expect(sessions.find { |x| x.id == "f23c8673" }).to be_needs_you
  end

  it "builds claude --bg arguments, leaving unset ones off" do
    a = described_class.spawn_args(
      "claude",
      prompt: "fix it", model: nil, effort: nil, permission_mode: nil, worktree: false, name: nil
    )
    expect(a).to eq(["claude", "--bg", "--", "fix it"])
    a = described_class.spawn_args(
      "claude",
      prompt: "fix it", model: "opus", effort: "high", permission_mode: "acceptEdits", worktree: true, name: "flaky"
    )
    expect(a).to eq(["claude", "--bg", "--model", "opus", "--effort", "high", "--permission-mode", "acceptEdits", "--name", "flaky", "--worktree", "--", "fix it"])
  end

  it "puts --remote-control last, where its optional name cannot eat the prompt" do
    a = described_class.spawn_args("claude", prompt: "fix it", name: "flaky", remote: true)
    expect(a).to eq(["claude", "--bg", "--name", "flaky", "--remote-control", "--", "fix it"])
  end

  it "keeps a prompt that starts with a dash a prompt" do
    a = described_class.spawn_args("claude", prompt: "-x is not a flag", remote: true)
    expect(a).to eq(["claude", "--bg", "--remote-control", "--", "-x is not a flag"])
  end

  it "mentions a file the way the CLI's own prompt does, spaces escaped" do
    expect(described_class.mention("/tmp/Screen Shot.png")).to eq("@/tmp/Screen\\ Shot.png")
  end

  it "ends an attach early when the block says so" do
    Dir.mktmpdir do |dir|
      bin = File.join(dir, "claude")
      File.write(bin, "#!/bin/sh\nsleep 5\n")
      File.chmod(0o755, bin)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      described_class.new(bin: bin).attach("abc12345") { true }
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 3
    end
  end

  it "reports an attach the CLI failed, and not one it ended itself" do
    Dir.mktmpdir do |dir|
      bin = File.join(dir, "claude")
      File.write(bin, "#!/bin/sh\n[ \"$2\" = bad ] && exit 1\nsleep 5\n")
      File.chmod(0o755, bin)
      client = described_class.new(bin: bin)
      expect(client.attach("bad") { false }).to be(false)
      expect(client.attach("abc12345") { true }).to be(true)
    end
  end
end
