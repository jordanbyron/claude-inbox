# frozen_string_literal: true

require "claude_inbox/settings"
require "tmpdir"
require "fileutils"
require "json"

RSpec.describe ClaudeInbox::Settings do
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
      expect(remote(home, proj)).to be_nil
      File.write("#{home}/.claude/settings.json", {remoteControlAtStartup: true}.to_json)
      expect(remote(home, proj)).to eq("yes")
      File.write("#{home}/.claude/settings.json", {remoteControlAtStartup: false}.to_json)
      expect(remote(home, proj)).to eq("no")
    end
  end

  it "falls back to the copy older versions kept in ~/.claude.json" do
    with_dirs do |home, proj|
      File.write("#{home}/.claude.json", {remoteControlAtStartup: true}.to_json)
      expect(remote(home, proj)).to eq("yes")
    end
  end

  it "lets a repo turn Remote Control off but not on" do
    with_dirs do |home, proj|
      File.write("#{proj}/.claude/settings.local.json", {remoteControlAtStartup: true}.to_json)
      expect(remote(home, proj)).to be_nil
      File.write("#{home}/.claude/settings.json", {remoteControlAtStartup: true}.to_json)
      File.write("#{proj}/.claude/settings.json", {remoteControlAtStartup: false}.to_json)
      expect(remote(home, proj)).to eq("no")
    end
  end
end
