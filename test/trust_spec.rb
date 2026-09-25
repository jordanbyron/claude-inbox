# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/claude_inbox/trust"
require "fileutils"
require "tmpdir"

describe ClaudeInbox::Trust do
  describe "projects" do
    def projects(path) = ClaudeInbox::Trust.projects(path: path)

    it "lists the directories whose trust dialog was accepted" do
      _(projects(fixture_path("claude.json"))).must_equal ["/Users/me/code/claude-inbox", "/Users/me/code/comma3"]
    end

    it "lists none when the file is missing, unparsable or another shape" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "claude.json")
        _(projects(path)).must_equal []
        ["{", "[]", '"projects"', '{"projects": []}', '{"projects": {"/x": true}}'].each do |body|
          File.write(path, body)
          _(projects(path)).must_equal []
        end
      end
    end

    it "skips a key that is not an absolute path" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "claude.json")
        accepted = {"hasTrustDialogAccepted" => true}
        File.write(path, JSON.generate("projects" => {"code/x" => accepted, "/a\0b" => accepted, "/ok" => accepted}))
        _(projects(path)).must_equal ["/ok"]
      end
    end
  end

  describe "covers?" do
    def covers?(dir, projects) = ClaudeInbox::Trust.covers?(dir, projects)

    it "matches a project and anything under it, by realpath" do
      Dir.mktmpdir do |tmp|
        repo = File.join(tmp, "repo")
        FileUtils.mkdir_p([File.join(repo, "lib"), File.join(tmp, "repo2")])
        link = File.join(tmp, "link")
        File.symlink(repo, link)

        _(covers?(repo, [link])).must_equal true
        _(covers?(File.join(link, "lib"), [repo])).must_equal true
        _(covers?(File.join(tmp, "repo2"), [repo])).must_equal false
        _(covers?(tmp, [repo])).must_equal false
        _(covers?(tmp, ["/"])).must_equal true
      end
    end

    it "matches nothing that is not there" do
      Dir.mktmpdir do |tmp|
        _(covers?(File.join(tmp, "gone"), [tmp])).must_equal false
        _(covers?(tmp, [File.join(tmp, "gone")])).must_equal false
        _(covers?(tmp, [])).must_equal false
      end
    end
  end
end
