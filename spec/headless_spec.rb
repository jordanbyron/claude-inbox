# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeInbox::Headless do
  let(:client) { instance_double(ClaudeInbox::AgentsClient) }

  it "exits at once while an inbox or another headless process holds the writer lock" do
    Dir.mktmpdir do |dir|
      lock = ClaudeInbox::WriterLock.new(path: File.join(dir, "writer.lock"))
      expect(lock.take(role: "inbox")).to be(true)
      headless = described_class.new(client: client, store: ClaudeInbox::Store.new(path: nil),
        lock: ClaudeInbox::WriterLock.new(path: File.join(dir, "writer.lock")))
      expect(headless.run).to be(false)
    end
  end

  describe "the update check" do
    let(:tmp) { Dir.mktmpdir }
    let(:path) { File.join(tmp, "snapshot.json") }
    let(:runs) { [] }
    let(:latest) { +"0.6.0" }
    let(:fetch) { ->(_) { %({"version":"#{latest}"}) } }
    let(:updater) do
      ClaudeInbox::Updater.new(checkout: false, version: "0.5.0", cache_path: File.join(tmp, "update.json"), fetch: fetch,
        run: ->(*argv) { runs << argv })
    end
    let(:headless) do
      described_class.new(client: RecordingClient.new, store: ClaudeInbox::Store.new(path: nil),
        pull_requests: ClaudeInbox::PullRequests.new(cache_path: nil, resolved_path: nil, gh: nil),
        actions: ClaudeInbox::Actions.disabled, snapshot: ClaudeInbox::Snapshot.new(path: path),
        lock: ClaudeInbox::WriterLock.new(path: File.join(tmp, "writer.lock")), updater: updater, recheck_every: 0.1)
    end
    let(:thread) { Thread.new { headless.run } }

    after do
      thread.kill.join
      FileUtils.remove_entry(tmp)
    end

    it "puts a newer release's notice in the snapshot and installs nothing" do
      thread
      expect(wait_for(timeout: 6) { File.exist?(path) && JSON.parse(File.read(path))["update"] == "v0.6.0 available" }).to be(true)
      expect(JSON.parse(File.read(path))["sections"].values.flatten.map { |r| r["id"] }).to include("f23c8673")
      expect(runs).to be_empty
    end

    # What `claude-inbox update` in a terminal leaves behind: the cache gone
    # and this version the latest.
    it "drops the notice once the update is applied elsewhere" do
      thread
      expect(wait_for(timeout: 6) { File.exist?(path) && JSON.parse(File.read(path))["update"] }).to be_truthy
      latest.replace("0.5.0")
      FileUtils.rm_f(File.join(tmp, "update.json"))
      expect(wait_for(timeout: 6) { !JSON.parse(File.read(path)).key?("update") }).to be(true)
    end

    context "when the check cannot reach rubygems.org" do
      let(:fetched) { [] }
      let(:fetch) do
        lambda do |url|
          fetched << url
          raise ClaudeInbox::Updater::Error, "rubygems.org is unreachable"
        end
      end

      # Asleep on its queue after the fetch: the check is over and polling goes on.
      it "keeps polling, with no notice in the snapshot" do
        thread
        expect(wait_for { fetched.any? && thread.status == "sleep" && File.exist?(path) }).to be(true)
        expect(JSON.parse(File.read(path))).not_to have_key("update")
        expect(runs).to be_empty
      end
    end
  end
end
