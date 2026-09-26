# frozen_string_literal: true

require_relative "test_helper"
require "claude_inbox/settings"
require "tmpdir"
require "fileutils"
require "json"

describe ClaudeInbox::Settings do
  def with_dirs
    Dir.mktmpdir do |home|
      Dir.mktmpdir do |proj|
        FileUtils.mkdir_p("#{home}/.claude")
        FileUtils.mkdir_p("#{proj}/.claude")
        yield home, proj
      end
    end
  end

  def remote(home, proj) = ClaudeInbox::Settings.defaults(proj, home: home).remote

  it "turns Remote Control on from user settings" do
    with_dirs do |home, proj|
      _(remote(home, proj)).must_be_nil
      File.write("#{home}/.claude/settings.json", {remoteControlAtStartup: true}.to_json)
      _(remote(home, proj)).must_equal "yes"
      File.write("#{home}/.claude/settings.json", {remoteControlAtStartup: false}.to_json)
      _(remote(home, proj)).must_equal "no"
    end
  end

  it "falls back to the copy older versions kept in ~/.claude.json" do
    with_dirs do |home, proj|
      File.write("#{home}/.claude.json", {remoteControlAtStartup: true}.to_json)
      _(remote(home, proj)).must_equal "yes"
    end
  end

  it "lets a repo turn Remote Control off but not on" do
    with_dirs do |home, proj|
      File.write("#{proj}/.claude/settings.local.json", {remoteControlAtStartup: true}.to_json)
      _(remote(home, proj)).must_be_nil
      File.write("#{home}/.claude/settings.json", {remoteControlAtStartup: true}.to_json)
      File.write("#{proj}/.claude/settings.json", {remoteControlAtStartup: false}.to_json)
      _(remote(home, proj)).must_equal "no"
    end
  end
end
