# frozen_string_literal: true

require "fileutils"
require "json"

# Writes a daemon job file (<dir>/<id>/state.json) for JobState to read.
module JobStateHelpers
  def write_job(dir, id, hash)
    FileUtils.mkdir_p(File.join(dir, id))
    File.write(File.join(dir, id, "state.json"), JSON.generate(hash))
  end
end

RSpec.configure { |config| config.include JobStateHelpers, :job_state }
