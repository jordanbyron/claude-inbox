# frozen_string_literal: true

require_relative "../lib/claude_inbox/trust"
require "tmpdir"

RSpec.describe ClaudeInbox::Trust do
  describe "projects" do
    def projects(path) = ClaudeInbox::Trust.projects(path: path)

    it "lists the directories whose trust dialog was accepted" do
      expect(projects(fixture_path("claude.json"))).to eq(["/Users/me/code/claude-inbox", "/Users/me/code/comma3"])
    end

    it "lists none when the file is missing, unparsable or another shape" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "claude.json")
        expect(projects(path)).to eq([])
        ["{", "[]", '"projects"', '{"projects": []}', '{"projects": {"/x": true}}'].each do |body|
          File.write(path, body)
          expect(projects(path)).to eq([])
        end
      end
    end

    it "skips a key that is not an absolute path" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "claude.json")
        accepted = {"hasTrustDialogAccepted" => true}
        File.write(path, JSON.generate("projects" => {"code/x" => accepted, "/a\0b" => accepted, "/ok" => accepted}))
        expect(projects(path)).to eq(["/ok"])
      end
    end
  end
end
