# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

JobState = ClaudeInbox::JobState

describe JobState do
  def write_job(dir, id, hash)
    FileUtils.mkdir_p(File.join(dir, id))
    File.write(File.join(dir, id, "state.json"), JSON.generate(hash))
  end

  it "reads the detail line, the pulse, the open work and the PR links" do
    Dir.mktmpdir do |dir|
      write_job(dir, "aaa11111",
        "state" => "working",
        "detail" => "watching CI re-run",
        "tempo" => "idle",
        "inFlight" => {"tasks" => 1},
        "fan" => [{"kind" => "shell", "label" => "gh pr checks --watch"}],
        "children" => [
          {"kind" => "pr", "href" => "https://github.com/o/r/pull/7"},
          {"kind" => "issue", "href" => "https://github.com/o/r/issues/8"}
        ])
      js = JobState.read("aaa11111", jobs_dir: dir)
      _(js.detail).must_equal "watching CI re-run"
      _(js.tempo).must_equal "idle"
      _(js.tasks).must_equal 1
      _(js.pr_urls).must_equal ["https://github.com/o/r/pull/7"]
      _(js).must_be :waiting_on_work?
      _(js.in_flight_label).must_equal "1 shell"
    end
  end

  it "is nil for a session with no readable file" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "bad00000"))
      File.write(File.join(dir, "bad00000", "state.json"), "{not json")
      _(JobState.read("bad00000", jobs_dir: dir)).must_be_nil
      _(JobState.read("gone0000", jobs_dir: dir)).must_be_nil
      _(JobState.read(nil, jobs_dir: dir)).must_be_nil
    end
  end

  it "counts each open task, translating the daemon's names" do
    js = JobState.new("inFlight" => {"tasks" => 3},
      "fan" => [{"kind" => "in_process_teammate"}, {"kind" => "in_process_teammate"}, {"kind" => "local_bash"}])
    _(js.in_flight_label).must_equal "2 agents · 1 shell"
  end

  it "keeps a name it does not know rather than inventing one" do
    js = JobState.new("inFlight" => {"tasks" => 1}, "fan" => [{"kind" => "sidecar"}])
    _(js.in_flight_label).must_equal "1 sidecar"
  end

  it "falls back to a bare count when the file does not name the work" do
    js = JobState.new("tempo" => "idle", "inFlight" => {"tasks" => 2})
    _(js.in_flight_label).must_equal "2 tasks"
    _(js).must_be :waiting_on_work?
  end

  it "says nothing about work when the agent is thinking or nothing is open" do
    thinking = JobState.new("tempo" => "active", "inFlight" => {"tasks" => 1}, "fan" => [{"kind" => "shell"}])
    _(thinking).wont_be :waiting_on_work?
    _(thinking.in_flight_label).must_equal "1 shell"

    # A session whose process died leaves an idle pulse behind with nothing in
    # flight; that is not the same as waiting, so it claims nothing.
    stalled = JobState.new("tempo" => "idle", "inFlight" => {"tasks" => 0})
    _(stalled).wont_be :waiting_on_work?
    _(stalled.in_flight_label).must_be_nil
  end

  it "reads the colour /color wrote into the job file" do
    _(JobState.read("b0b18338", jobs_dir: fixture_path("jobs")).color).must_equal "orange"
    _(JobState.read("b03695b1", jobs_dir: fixture_path("jobs")).color).must_be_nil
    _(JobState.new({}).color).must_be_nil
  end

  it "enriches background sessions only" do
    Dir.mktmpdir do |dir|
      write_job(dir, "aaa11111", "tempo" => "idle", "inFlight" => {"tasks" => 1}, "fan" => [{"kind" => "shell"}])
      bg = session(id: "aaa11111")
      term = session(id: nil, kind: "interactive", state: nil, status: "busy", session_id: "u1")
      JobState.enrich([bg, term], jobs_dir: dir)
      _(bg.job_state.in_flight_label).must_equal "1 shell"
      _(bg).must_be :waiting_on_work?
      _(term.job_state).must_be_nil
    end
  end
end
