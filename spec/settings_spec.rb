# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "json"

RSpec.describe ClaudeInbox::Settings, :settings do
  let(:home) { Dir.mktmpdir }
  let(:proj) { Dir.mktmpdir }

  before do
    FileUtils.mkdir_p("#{home}/.claude")
    FileUtils.mkdir_p("#{proj}/.claude")
  end

  after { FileUtils.rm_rf([home, proj]) }

  it "turns Remote Control on from user settings" do
    expect(remote).to be_nil
    File.write("#{home}/.claude/settings.json", {remoteControlAtStartup: true}.to_json)
    expect(remote).to eq("yes")
    File.write("#{home}/.claude/settings.json", {remoteControlAtStartup: false}.to_json)
    expect(remote).to eq("no")
  end

  it "falls back to the copy older versions kept in ~/.claude.json" do
    File.write("#{home}/.claude.json", {remoteControlAtStartup: true}.to_json)
    expect(remote).to eq("yes")
  end

  it "lets a repo turn Remote Control off but not on" do
    File.write("#{proj}/.claude/settings.local.json", {remoteControlAtStartup: true}.to_json)
    expect(remote).to be_nil
    File.write("#{home}/.claude/settings.json", {remoteControlAtStartup: true}.to_json)
    File.write("#{proj}/.claude/settings.json", {remoteControlAtStartup: false}.to_json)
    expect(remote).to eq("no")
  end
end
