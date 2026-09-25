# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "tmpdir"
require_relative "../release/lockfile"

describe Release::Lockfile do
  root = File.expand_path("..", __dir__)

  before do
    @dir = Dir.mktmpdir
    FileUtils.cp_r(%w[Gemfile Gemfile.lock claude-inbox.gemspec lib].map { |f| File.join(root, f) }, @dir)
    # The gemspec lists its files with git ls-files.
    system("git", "init", "--quiet", chdir: @dir)
  end

  after { FileUtils.rm_rf(@dir) }

  it "reads the version the lock records for the gem" do
    _(Release::Lockfile.new(@dir).version).must_equal ClaudeInbox::VERSION
  end

  it "relocks to the VERSION the gemspec now reports" do
    version_file = File.join(@dir, "lib/claude_inbox.rb")
    File.write(version_file, File.read(version_file).sub(/VERSION = ".*"/, 'VERSION = "99.0.0"'))
    lockfile = Release::Lockfile.new(@dir)

    _(lockfile.sync).must_equal true
    _(lockfile.version).must_equal "99.0.0"
    _(File.read(File.join(@dir, "Gemfile.lock"))).wont_include "claude-inbox (#{ClaudeInbox::VERSION})"
  end
end
