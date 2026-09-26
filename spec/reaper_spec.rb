# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeInbox::Reaper do
  subject(:reaper) { described_class.new(client, store, log_path: log_path) }

  let(:now) { Time.at(1_789_600_000) }
  # merge_entries dates a finished session with no process from `started_at`,
  # so an old `started_at` is the whole of the setup needed to look long idle.
  let(:quiet) { {state: "done", started_at: Time.at(now.to_i - ClaudeInbox::Store::REAP_AFTER - 86_400)} }
  let(:client) { RecordingClient.new }
  let(:store) { ClaudeInbox::Store.new(path: nil, clock: -> { now }).tap { |s| s.update(sessions) } }
  let(:dir) { Dir.mktmpdir }
  let(:log_path) { File.join(dir, "reaped.log") }

  after { FileUtils.remove_entry(dir) if Dir.exist?(dir) }

  context "with two sessions long quiet" do
    let(:sessions) { [session(id: "old1", **quiet), session(id: "old2", name: "auth spike", **quiet)] }

    it "removes the sessions that are due, forgets them, and logs each one" do
      expect(reaper.sweep(sessions, now).sort).to eq(%w[old1 old2])
      expect(client.removed.sort).to eq(%w[old1 old2])
      expect(store.entry("old1")).to be_nil
      expect(store.entry("old2")).to be_nil
      log = File.read(log_path)
      expect(log.lines.size).to eq(2)
      expect(log).to include("idle 15d")
      expect(log).to include("\"auth spike\"")
      expect(log).to include("reaped")
    end
  end

  context "with one session long quiet and one still working" do
    let(:sessions) { [session(id: "old1", **quiet), session(id: "busy", state: "working")] }

    it "names what it is about to take without taking anything" do
      expect(reaper.due(sessions, now)).to eq(%w[old1])
      expect(client.removed).to be_empty
      expect(store.entry("old1")).not_to be_nil
      expect(File.exist?(log_path)).to be(false)
      expect(described_class.disabled.due(sessions, now)).to be_empty
    end
  end

  context "with a session only just finished" do
    let(:sessions) { [session(id: "fresh", state: "done")] }

    it "leaves a session that has not been quiet long enough, and writes no log at all" do
      expect(reaper.sweep(sessions, now)).to be_empty
      expect(client.removed).to be_empty
      expect(File.exist?(log_path)).to be(false)
    end
  end

  context "with a session that ran for weeks and has just finished" do
    let(:sessions) { [session(id: "long", **quiet, state: "working")] }
    let(:just_finished) { session(id: "long", **quiet) }

    before { store.update([just_finished]) }

    it "dates idleness from the last state change, not from when the session started" do
      expect(reaper.sweep([just_finished], now)).to be_empty
      expect(client.removed).to be_empty
    end
  end

  context "when a worktree refuses" do
    let(:client) { RecordingClient.new(refuse: %w[unpushed]) }

    context "alongside one that does not" do
      let(:sessions) { [session(id: "unpushed", **quiet), session(id: "clean", **quiet)] }

      it "keeps a session whose worktree refuses, and carries on with the rest" do
        expect(reaper.sweep(sessions, now)).to eq(%w[clean])
        expect(store.entry("unpushed")["reap_failed_at"]).to eq(now.to_i)
        expect(store.entry("unpushed")["reap_error"]).to include("unpushed commits")
        expect(store.entry("clean")).to be_nil
        expect(File.read(log_path)).to include("kept — rm failed: worktree has unpushed commits")
      end
    end

    context "on its own" do
      let(:sessions) { [session(id: "unpushed", **quiet)] }

      it "backs off a refused session for RETRY_AFTER, then tries once more" do
        reaper.sweep(sessions, now)
        expect(reaper.sweep(sessions, now + described_class::RETRY_AFTER - 60)).to be_empty
        expect(File.readlines(log_path).size).to eq(1)

        reaper.sweep(sessions, now + described_class::RETRY_AFTER + 60)
        expect(File.readlines(log_path).size).to eq(2)
      end
    end
  end

  context "when the log cannot be written" do
    let(:sessions) { [session(id: "old1", **quiet)] }
    let(:log_path) { File.join(dir, "blocked", "reaped.log") }

    before { File.write(File.join(dir, "blocked"), "not a directory") }

    it "refuses to reap anything it cannot write an audit line for" do
      expect { reaper.sweep(sessions, now) }.to raise_error(SystemCallError)
      expect(client.removed).to be_empty
      expect(store.entry("old1")).not_to be_nil
    end
  end

  describe "#report" do
    let(:store) { nil }

    it "words what it took for the notice, and says where the log is" do
      expect(reaper.report(%w[old1])).to eq("reaped 1 session idle over 14d — see #{log_path}")
      expect(reaper.report(%w[old1 old2])).to eq("reaped 2 sessions idle over 14d — see #{log_path}")
    end
  end

  it "does nothing at all when disabled" do
    expect(described_class.disabled.sweep([session(id: "old1", **quiet)], now)).to be_empty
  end

  it "reads CLAUDE_INBOX_NO_REAP as the off switch" do
    original = ENV["CLAUDE_INBOX_NO_REAP"]
    ENV["CLAUDE_INBOX_NO_REAP"] = "1"
    expect(described_class.enabled?).to be(false)
    ENV["CLAUDE_INBOX_NO_REAP"] = ""
    expect(described_class.enabled?).to be(true)
  ensure
    ENV["CLAUDE_INBOX_NO_REAP"] = original
  end
end
