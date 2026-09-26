# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "json"

RSpec.describe ClaudeInbox::Settings do
  subject(:remote) { described_class.defaults(proj, home: home).remote }

  let(:home) { Dir.mktmpdir }
  let(:proj) { Dir.mktmpdir }

  before do
    FileUtils.mkdir_p("#{home}/.claude")
    FileUtils.mkdir_p("#{proj}/.claude")
  end

  after { FileUtils.rm_rf([home, proj]) }

  it "leaves Remote Control unset with no settings" do
    expect(remote).to be_nil
  end

  it "turns Remote Control on from user settings" do
    File.write("#{home}/.claude/settings.json", {remoteControlAtStartup: true}.to_json)
    expect(remote).to eq("yes")
  end

  it "turns Remote Control off from user settings" do
    File.write("#{home}/.claude/settings.json", {remoteControlAtStartup: false}.to_json)
    expect(remote).to eq("no")
  end

  it "falls back to the copy older versions kept in ~/.claude.json" do
    File.write("#{home}/.claude.json", {remoteControlAtStartup: true}.to_json)
    expect(remote).to eq("yes")
  end

  it "doesn't let a repo turn Remote Control on" do
    File.write("#{proj}/.claude/settings.local.json", {remoteControlAtStartup: true}.to_json)
    expect(remote).to be_nil
  end

  it "lets a repo turn Remote Control off" do
    File.write("#{home}/.claude/settings.json", {remoteControlAtStartup: true}.to_json)
    File.write("#{proj}/.claude/settings.json", {remoteControlAtStartup: false}.to_json)
    expect(remote).to eq("no")
  end
end
