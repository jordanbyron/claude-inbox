# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeInbox::Claude::Roster do
  it "reads what the session's process says it is doing" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "7.json"), JSON.generate("pid" => 7, "jobId" => "aaa11111", "status" => "shell", "statusUpdatedAt" => 1793409689178))
      expect(described_class.status(7, dir: dir)).to eq("shell")
      File.write(File.join(dir, "7.json"), JSON.generate("pid" => 7, "status" => "busy"))
      expect(described_class.status(7, dir: dir)).to eq("busy")
    end
  end

  it "is nil without a readable file, or a status in it" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "8.json"), "{not json")
      File.write(File.join(dir, "9.json"), JSON.generate("pid" => 9))
      expect(described_class.status(8, dir: dir)).to be_nil
      expect(described_class.status(9, dir: dir)).to be_nil
      expect(described_class.status(10, dir: dir)).to be_nil
      expect(described_class.status(nil, dir: dir)).to be_nil
    end
  end
end
