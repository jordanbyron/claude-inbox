# frozen_string_literal: true

require_relative "test_helper"

JobState = ClaudeInbox::JobState

describe JobState do
  let(:jobs) { JobState.new(jobs_dir: fixture_path("jobs")) }

  it "reads the colour /color wrote into a job's state file" do
    _(jobs.color("b0b18338")).must_equal "orange"
  end

  it "has no colour for a job that was never coloured, or that does not exist" do
    _(jobs.color("b03695b1")).must_be_nil
    _(jobs.color("nope")).must_be_nil
    _(jobs.color(nil)).must_be_nil
  end

  it "reads the pr and issue links the daemon scanned" do
    _(jobs.children("b0b18338").map { |c| c["id"] }).must_equal %w[885]
    _(jobs.children("nope")).must_be_empty
  end

  it "survives a job file that is not json" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "bad"))
      File.write(File.join(dir, "bad", "state.json"), "{ not json")
      broken = JobState.new(jobs_dir: dir)
      _(broken.color("bad")).must_be_nil
      _(broken.children("bad")).must_be_empty
    end
  end

  it "enriches sessions with their colour, ignoring ones with no job" do
    coloured = session(id: "b0b18338")
    plain = session(id: "b03695b1")
    interactive = session(id: nil, kind: "interactive")
    jobs.enrich([coloured, plain, interactive])
    _(coloured.color).must_equal "orange"
    _(plain.color).must_be_nil
    _(interactive.color).must_be_nil
  end
end
