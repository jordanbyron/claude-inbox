# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeInbox::Trust do
  describe "projects" do
    it "lists the directories whose trust dialog was accepted" do
      expect(described_class.projects(path: fixture_path("claude.json"))).to eq(["/Users/me/code/claude-inbox", "/Users/me/code/comma3"])
    end

    it "lists none when the file is missing, unparsable or another shape" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "claude.json")
        expect(described_class.projects(path: path)).to eq([])
        ["{", "[]", '"projects"', '{"projects": []}', '{"projects": {"/x": true}}'].each do |body|
          File.write(path, body)
          expect(described_class.projects(path: path)).to eq([])
        end
      end
    end

    it "skips a key that is not an absolute path" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "claude.json")
        accepted = {"hasTrustDialogAccepted" => true}
        File.write(path, JSON.generate("projects" => {"code/x" => accepted, "/a\0b" => accepted, "/ok" => accepted}))
        expect(described_class.projects(path: path)).to eq(["/ok"])
      end
    end
  end
end
