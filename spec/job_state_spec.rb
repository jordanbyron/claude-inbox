# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeInbox::JobState, :job_state do
  it "reads the detail line, the pulse, the open work and the PR links" do
    Dir.mktmpdir do |dir|
      write_job(dir, "aaa11111",
        "state" => "working",
        "detail" => "watching CI re-run",
        "needs" => "confirm: merge once green?",
        "output" => {"result" => "CI re-run passed"},
        "tempo" => "idle",
        "bridgeSessionId" => "cse_01AB",
        "respawnFlags" => ["--remote-control", "--model", "opus"],
        "inFlight" => {"tasks" => 1},
        "fan" => [{"kind" => "shell", "label" => "gh pr checks --watch"}],
        "children" => [
          {"kind" => "pr", "href" => "https://github.com/o/r/pull/7"},
          {"kind" => "issue", "href" => "https://github.com/o/r/issues/8"}
        ])
      js = described_class.read("aaa11111", jobs_dir: dir)
      expect(js.detail).to eq("watching CI re-run")
      expect(js.needs).to eq("confirm: merge once green?")
      expect(js.result).to eq("CI re-run passed")
      expect(js.pr_urls).to eq(["https://github.com/o/r/pull/7"])
      expect(js.bridge_id).to eq("cse_01AB")
      expect(js).to be_remote_control
      expect(described_class.new({})).not_to be_remote_control
      expect(js).to be_waiting_on_work
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
    expect(js).to be_waiting_on_work
  end

  it "says nothing about work when the agent is thinking or nothing is open" do
    thinking = described_class.new("tempo" => "active", "inFlight" => {"tasks" => 1}, "fan" => [{"kind" => "shell"}])
    expect(thinking).not_to be_waiting_on_work
    expect(thinking.in_flight_label).to eq("1 shell")

    # A session whose process died leaves an idle pulse behind with nothing in
    # flight; that is not the same as waiting, so it claims nothing.
    stalled = described_class.new("tempo" => "idle", "inFlight" => {"tasks" => 0})
    expect(stalled).not_to be_waiting_on_work
    expect(stalled.in_flight_label).to be_nil
  end

  it "has no needs or result when the file carries neither" do
    js = described_class.new("detail" => "thinking")
    expect(js.needs).to be_nil
    expect(js.result).to be_nil
  end

  it "summarizes by state: needs while blocked, result once done, else the detail line" do
    js = described_class.new("detail" => "watching\n  CI", "needs" => "confirm: merge?", "output" => {"result" => "PR #7 up"})
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

  it "reads the prompt the session was started with" do
    js = described_class.new({"intent" => "Look into the TIAA gateway 403s"})
    expect(js.intent).to eq("Look into the TIAA gateway 403s")
    expect(described_class.new({}).intent).to be_nil
  end

  it "enriches background sessions only" do
    Dir.mktmpdir do |dir|
      write_job(dir, "aaa11111", "tempo" => "idle", "inFlight" => {"tasks" => 1}, "fan" => [{"kind" => "shell"}])
      bg, term = described_class.enrich([
        session(id: "aaa11111"),
        session(id: nil, kind: "interactive", state: nil, status: "busy", session_id: "u1")
      ], jobs_dir: dir)
      expect(bg.job_state.in_flight_label).to eq("1 shell")
      expect(bg).to be_waiting_on_work
      expect(term.job_state).to be_nil
    end
  end
end
