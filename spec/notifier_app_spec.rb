# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeInbox::NotifierApp do
  let(:dir) { Dir.mktmpdir }
  let(:prefix) { File.join(dir, "Cellar", "terminal-notifier", "3.1.0") }
  let(:source) { File.realpath(File.join(prefix, "terminal-notifier.app")) }
  let(:path) { File.join(dir, "notifier.app") }
  let(:runs) { [] }
  let(:steps_succeed) { true }
  let(:brew_out) { "#{prefix}\n" }
  let(:run) do
    lambda do |*argv|
      runs << argv
      ok = (argv.first == "brew") ? !brew_out.nil? : steps_succeed
      ClaudeInbox::Subprocess::Result.new(brew_out.to_s, "", instance_double(Process::Status, success?: ok))
    end
  end
  let(:app) { described_class.new(path: path, run: run) }

  before do
    FileUtils.mkdir_p(File.join(prefix, "terminal-notifier.app", "Contents", "MacOS"))
    FileUtils.mkdir_p(File.join(prefix, "terminal-notifier.app", "Contents", "Resources"))
    File.write(File.join(prefix, "terminal-notifier.app", "Contents", "Info.plist"), "<plist/>")
  end

  after { FileUtils.rm_rf(dir) }

  it "builds a copy under its own id and icon, and opens it once to be asked permission" do
    app.prepare
    expect(File.exist?(File.join(path, "Contents", "Resources", "claude-inbox.icns"))).to be(true)
    plist = File.join(path, "Contents", "Info.plist")
    expect(runs).to include(
      ["plutil", "-replace", "CFBundleIdentifier", "-string", described_class::ID, a_string_ending_with("notifier.app.tmp/Contents/Info.plist")],
      ["codesign", "--force", "--sign", "-", "#{path}.tmp"]
    )
    expect(runs.last).to start_with("open", "-n", path, "--args")
    expect(File.exist?(plist)).to be(true)
    expect(app.command).to eq([File.join(path, "Contents", "MacOS", "terminal-notifier")])
  end

  it "keeps a copy built from the same app, and rebuilds one from another version" do
    app.prepare
    runs.clear
    described_class.new(path: path, run: run).prepare
    expect(runs).to eq([["brew", "--prefix", "terminal-notifier"]])

    File.write(File.join(path, "Contents", "Resources", "source"), "/elsewhere/2.0.0/terminal-notifier.app")
    runs.clear
    described_class.new(path: path, run: run).prepare
    expect(runs.map(&:first)).to include("codesign", "open")
  end

  context "without Homebrew's terminal-notifier" do
    let(:brew_out) { nil }

    it "builds nothing and falls back to terminal-notifier with the icon as a thumbnail" do
      app.prepare
      expect(File.exist?(path)).to be(false)
      expect(app.command).to eq(["terminal-notifier", "-contentImage", described_class::PNG])
    end
  end

  context "when signing fails" do
    let(:steps_succeed) { false }

    it "leaves no copy behind and opens nothing" do
      app.prepare
      expect(Dir.children(dir)).to eq(["Cellar"])
      expect(runs.map(&:first)).not_to include("open")
      expect(app.command).to eq(described_class::FALLBACK)
    end
  end

  it "is plain terminal-notifier when disabled" do
    disabled = described_class.disabled
    disabled.prepare
    expect(disabled.command).to eq(described_class::FALLBACK)
  end
end
