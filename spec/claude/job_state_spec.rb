# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeInbox::Claude::JobState do
  it "reads the detail line, the pulse, the open work and the PR links" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "aaa11111"))
      File.write(File.join(dir, "aaa11111", "state.json"), JSON.generate(
        "state" => "working",
        "detail" => "watching CI re-run",
        "needs" => "confirm: merge once green?",
        "output" => {"result" => "CI re-run passed"},
        "tempo" => "idle",
        "bridgeSessionId" => "cse_01AB",
        "linkScanPath" => "/t/aaa.jsonl",
        "createdAt" => "2026-10-14T11:00:23.329Z",
        "respawnFlags" => ["--remote-control", "--model", "opus"],
        "inFlight" => {"tasks" => 1},
        "fan" => [{"kind" => "shell", "label" => "gh pr checks --watch"}],
        "children" => [
          {"kind" => "pr", "href" => "https://github.com/o/r/pull/7"},
          {"kind" => "issue", "href" => "https://github.com/o/r/issues/8"}
        ]
      ))
      js = described_class.read("aaa11111", jobs_dir: dir)
      expect(js.summary("working")).to eq("watching CI re-run")
      expect(js.summary("blocked")).to eq("confirm: merge once green?")
      expect(js.summary("done")).to eq("CI re-run passed")
      expect(js.pr_urls).to eq(["https://github.com/o/r/pull/7"])
      expect(js.bridge_id).to eq("cse_01AB")
      expect(js.transcript_path).to eq("/t/aaa.jsonl")
      expect(js.created_at).to eq(Time.utc(2026, 10, 14, 11, 0, 23.329r))
      expect(described_class.new("createdAt" => "soon").created_at).to be_nil
      expect(js).to be_remote_control
      expect(described_class.new({})).not_to be_remote_control
      expect(js).to be_agent_idle
      expect(js).to be_in_flight
      expect(js.in_flight_label).to eq("1 shell")
    end
  end

  it "is nil for a session with no readable file" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "bad00000"))
      File.write(File.join(dir, "bad00000", "state.json"), "{not json")
      expect(described_class.read("bad00000", jobs_dir: dir)).to be_nil
      expect(described_class.read("gone0000", jobs_dir: dir)).to be_nil
      expect(described_class.read(nil, jobs_dir: dir)).to be_nil
    end
  end

  it "counts each open task, translating the daemon's names" do
    js = described_class.new("inFlight" => {"tasks" => 3},
      "fan" => [{"kind" => "in_process_teammate"}, {"kind" => "in_process_teammate"}, {"kind" => "local_bash"}])
    expect(js.in_flight_label).to eq("2 agents · 1 shell")
  end

  it "keeps a name it does not know rather than inventing one" do
    js = described_class.new("inFlight" => {"tasks" => 1}, "fan" => [{"kind" => "sidecar"}])
    expect(js.in_flight_label).to eq("1 sidecar")
  end

  it "falls back to a bare count when the file does not name the work" do
    js = described_class.new("tempo" => "idle", "inFlight" => {"tasks" => 2})
    expect(js.in_flight_label).to eq("2 tasks")
    expect(js).to be_agent_idle
    expect(js).to be_in_flight
  end

  it "knows a thinking agent from one gone quiet, and what is open either way" do
    thinking = described_class.new("tempo" => "active", "inFlight" => {"tasks" => 1}, "fan" => [{"kind" => "shell"}])
    expect(thinking).not_to be_agent_idle
    expect(thinking).to be_in_flight
    expect(thinking.in_flight_label).to eq("1 shell")

    stalled = described_class.new("tempo" => "idle", "inFlight" => {"tasks" => 0})
    expect(stalled).to be_agent_idle
    expect(stalled).not_to be_in_flight
    expect(stalled.in_flight_label).to be_nil
    expect(described_class.new({})).not_to be_in_flight
  end

  it "reads the turn as over from the timeline's last record carrying the reply" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "aaa11111"))
      File.write(File.join(dir, "aaa11111", "state.json"), JSON.generate("state" => "working"))
      timeline = File.join(dir, "aaa11111", "timeline.jsonl")
      File.write(timeline, [
        {"at" => "2026-10-30T13:19:10.604Z", "state" => "working", "detail" => "Finding files", "text" => ""},
        {"at" => "2026-10-30T13:26:00.646Z", "state" => "working", "detail" => "tier 1 works", "text" => "Recap: " + ("x" * 4000)}
      ].map { |r| JSON.generate(r) }.join("\n") + "\n")
      expect(described_class.read("aaa11111", jobs_dir: dir)).to be_turn_over

      # The prompt that starts the next turn, and every tool call after it,
      # is a record without a reply.
      File.write(timeline, JSON.generate("at" => "2026-10-30T14:25:40.804Z", "state" => "working", "detail" => "go on", "text" => "") + "\n", mode: "a")
      expect(described_class.read("aaa11111", jobs_dir: dir)).not_to be_turn_over

      File.delete(timeline)
      expect(described_class.read("aaa11111", jobs_dir: dir)).not_to be_turn_over
      expect(described_class.new({})).not_to be_turn_over
    end
  end

  it "reads a last record longer than its first tail, with or without a final newline, and not one half written" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "aaa11111"))
      File.write(File.join(dir, "aaa11111", "state.json"), "{}")
      timeline = File.join(dir, "aaa11111", "timeline.jsonl")
      long = JSON.generate("state" => "done", "text" => "y" * (described_class::TAIL * 3))
      short = JSON.generate("state" => "working", "text" => "")
      File.write(timeline, "#{short}\n#{long}\n")
      expect(described_class.read("aaa11111", jobs_dir: dir)).to be_turn_over
      File.write(timeline, "#{short}\n#{long}")
      expect(described_class.read("aaa11111", jobs_dir: dir)).to be_turn_over
      File.write(timeline, long)
      expect(described_class.read("aaa11111", jobs_dir: dir)).to be_turn_over

      # The daemon appending: the cut-off record is no reply yet.
      File.write(timeline, "#{short}\n#{long[0, 100]}")
      expect(described_class.read("aaa11111", jobs_dir: dir)).not_to be_turn_over
      File.write(timeline, "")
      expect(described_class.read("aaa11111", jobs_dir: dir)).not_to be_turn_over
    end
  end

  it "settles on the state the session filed with its reply when it is blocked or done" do
    expect(described_class.new("state" => "blocked").settled_state).to eq("blocked")
    expect(described_class.new("state" => "done").settled_state).to eq("done")
    expect(described_class.new("state" => "working").settled_state).to be_nil
    expect(described_class.new({}).settled_state).to be_nil
  end

  it "falls back to the detail line when the file has no needs or result" do
    js = described_class.new("detail" => "thinking")
    expect(js.summary("blocked")).to eq("thinking")
    expect(js.summary("done")).to eq("thinking")
  end

  it "summarizes by state: needs while blocked, result once done, else the detail line" do
    js = described_class.new(
      "detail" => "watching\n  CI",
      "needs" => "confirm: merge?",
      "output" => {"result" => "PR #7 up"}
    )
    expect(js.summary("blocked")).to eq("confirm: merge?")
    expect(js.summary("done")).to eq("PR #7 up")
    expect(js.summary("working")).to eq("watching CI")
    expect(described_class.new("detail" => "watching CI").summary("blocked")).to eq("watching CI")
    expect(described_class.new({}).summary("done")).to be_nil
  end

  it "reads the color /color wrote into the job file" do
    expect(described_class.read("b0b18338", jobs_dir: fixture_path("jobs")).color).to eq("orange")
    expect(described_class.read("b03695b1", jobs_dir: fixture_path("jobs")).color).to be_nil
    expect(described_class.new({}).color).to be_nil
  end

  it "writes a color into the job file, keeping the rest, and leaves a missing file alone" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "aaa11111"))
      File.write(File.join(dir, "aaa11111", "state.json"), JSON.generate("intent" => "go", "color" => "red"))
      described_class.write_color("aaa11111", "pink", jobs_dir: dir)
      expect(JSON.parse(File.read(File.join(dir, "aaa11111", "state.json")))).to eq("intent" => "go", "color" => "pink")
      expect(described_class.write_color("gone0000", "pink", jobs_dir: dir)).to be_nil
    end
  end

  it "reads the prompt the session was started with" do
    js = described_class.new({"intent" => "Look into the TIAA gateway 403s"})
    expect(js.intent).to eq("Look into the TIAA gateway 403s")
    expect(described_class.new({}).intent).to be_nil
  end
end
