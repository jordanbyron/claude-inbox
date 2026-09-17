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
      _(js).must_be :agent_idle?
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
  end

  # The two records of open work disagree on live sessions: a state file can
  # name a sub-agent in `fan` while `inFlight` still counts nothing, and count
  # three tasks while naming two. Either one means something is open.
  it "takes open work from whichever of the two records has it" do
    named_only = JobState.new("inFlight" => {"tasks" => 0}, "fan" => [{"kind" => "in_process_teammate"}])
    _(named_only).must_be :in_flight?
    _(named_only.in_flight_label).must_equal "1 agent"

    _(JobState.new("inFlight" => {"tasks" => 0})).wont_be :in_flight?
  end

  it "enriches background sessions only" do
    Dir.mktmpdir do |dir|
      write_job(dir, "aaa11111", "tempo" => "idle", "inFlight" => {"tasks" => 1}, "fan" => [{"kind" => "shell"}])
      bg = session(id: "aaa11111")
      term = session(id: nil, kind: "interactive", state: nil, status: "busy", session_id: "u1")
      JobState.enrich([bg, term], jobs_dir: dir)
      _(bg.job_state.in_flight_label).must_equal "1 shell"
      _(bg).must_be :idling?
      _(term.job_state).must_be_nil
    end
  end
end

describe ClaudeInbox::Session do
  # Measured against transcript freshness on nine live sessions: `status` says
  # busy while a session only holds background shells, and `tempo` keeps
  # claiming active long after the session stopped writing its file. Neither
  # calls a thinking agent idle, so one saying idle is enough.
  it "believes either source that says the agent has stopped" do
    idle_file = ClaudeInbox::JobState.new("tempo" => "idle", "inFlight" => {"tasks" => 1}, "fan" => [{"kind" => "shell"}])
    stale_file = ClaudeInbox::JobState.new("tempo" => "active", "inFlight" => {"tasks" => 0})

    _(session(status: "busy", job_state: idle_file)).must_be :idling?
    _(session(status: "idle", job_state: stale_file)).must_be :idling?
    _(session(status: "busy", job_state: stale_file)).wont_be :idling?
    _(session(status: nil, job_state: nil)).wont_be :idling?
  end

  it "only calls a session idle while the daemon still calls it working" do
    idle_file = ClaudeInbox::JobState.new("tempo" => "idle", "inFlight" => {"tasks" => 1})
    _(session(state: "done", status: "idle", job_state: idle_file)).wont_be :idling?
    _(session(state: "blocked", status: "idle", job_state: idle_file)).wont_be :idling?
  end
end
