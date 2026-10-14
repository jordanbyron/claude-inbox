# frozen_string_literal: true

require "stringio"
require "tmpdir"

RSpec.describe ClaudeInbox::App do
  let(:terminal) { ScreenTerminal.new }

  let(:client) { RecordingClient.new }
  let(:store) { ClaudeInbox::Store.new(path: nil) }
  let(:pull_requests) { ClaudeInbox::PullRequests.new(cache_path: nil, resolved_path: nil, gh: nil) }
  let(:queue) { Queue.new }

  let(:app) do
    described_class.new(
      client: client, store: store, pull_requests: pull_requests,
      rate_limits: ClaudeInbox::RateLimits.new(path: fixture_path("rate_limits.json")),
      terminal: terminal, input: StringIO.new, color: false, queue: queue
    )
  end

  before do
    store.update(ClaudeInbox::Sessions.load(client: client, pull_requests: pull_requests, overrides: {}))
    app.step
  end

  after { client.release }

  it "says on U that the update check is off when there is no updater" do
    press(app, "U")
    expect(app).to paint("update check is off").in_status_line
  end

  describe "a newer release" do
    let(:tmp) { Dir.mktmpdir }
    let(:out) { StringIO.new }
    let(:execs) { [] }
    let(:fetch) { ->(_) { '{"version":"0.6.0"}' } }
    let(:install) { ["Successfully installed claude-inbox-0.6.0\n", true] }
    let(:updater) do
      ClaudeInbox::Updater.new(
        checkout: false, version: "0.5.0", cache_path: File.join(tmp, "update.json"), fetch: fetch,
        run: ->(*) { ClaudeInbox::Subprocess::Result.new(install[0], "", instance_double(Process::Status, success?: install[1])) },
        exec: ->(*argv) { execs << argv }
      )
    end
    let(:snapshot_path) { File.join(tmp, "snapshot.json") }
    let(:app) do
      described_class.new(
        client: client, store: store, pull_requests: pull_requests,
        rate_limits: ClaudeInbox::RateLimits.new(path: fixture_path("rate_limits.json")),
        terminal: terminal, input: StringIO.new, out: out, color: false, queue: queue,
        snapshot: ClaudeInbox::Snapshot.new(path: snapshot_path), updater: updater, argv: ["--listen-lan"]
      )
    end

    # The first poll's landing takes "polling…" out of the header's slot.
    before { queue << [:sessions] }

    after { FileUtils.remove_entry(tmp) }

    it "offers it in the header, behind any notice, and U installs it and relaunches with the same arguments" do
      expect(wait_for { screen(app).first.include?("v0.6.0 available · U updates") }).to be(true)
      press(app, "x")
      expect(app).to paint("settled — u brings it back").in_status_line
      expect(app).not_to paint("v0.6.0 available").in_status_line

      press(app, "U")
      expect(out.string).to include("Installing claude-inbox 0.6.0 over 0.5.0...", "Successfully installed")
      expect(execs).to eq([["claude-inbox", "--listen-lan"]])
      expect(terminal.pauses).to eq(0)
    end

    it "puts the notice in the snapshot for the pane" do
      expect(wait_for { screen(app).first.include?("v0.6.0 available") }).to be(true)
      expect(JSON.parse(File.read(snapshot_path))["update"]).to eq("v0.6.0 available")
    end

    it "holds a failed install's error on screen, then relaunches this version rather than stay at the shell" do
      install.replace(["ERROR:  Could not find a valid gem 'claude-inbox'", false])
      expect(wait_for { screen(app).first.include?("U updates") }).to be(true)
      press(app, "U")
      expect(out.string).to include("Could not find a valid gem")
      expect(terminal.pauses).to eq(1)
      expect(execs).to eq([["claude-inbox", "--listen-lan"]])
    end

    context "when the check cannot reach rubygems.org" do
      let(:fetch) { ->(_) { raise ClaudeInbox::Updater::Error, "rubygems.org is unreachable" } }

      it "keeps the header quiet and lets U say why" do
        expect(wait_for {
          press(app, "U")
          screen(app).first.include?("couldn't check for updates: rubygems.org is unreachable")
        }).to be(true)
        expect(screen(app).first).not_to include("⚠")
        expect(execs).to be_empty
      end
    end

    context "when this is the latest release" do
      let(:fetch) { ->(_) { '{"version":"0.5.0"}' } }

      it "shows nothing, and U says so" do
        expect(wait_for {
          press(app, "U")
          screen(app).first.include?("up to date")
        }).to be(true)
        expect(screen(app).first).not_to include("U updates")
        expect(JSON.parse(File.read(snapshot_path))).not_to have_key("update")
        expect(execs).to be_empty
        expect(out.string).to be_empty
      end
    end
  end
end
