# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeInbox::Reaper do
  let(:now) { Time.at(1_789_600_000) }
  # merge_entries dates a finished session with no process from `started_at`,
  # so an old `started_at` is the whole of the setup needed to look long idle.
  let(:quiet_since) { now.to_i - ClaudeInbox::Store::REAP_AFTER - 86_400 }
  let(:client) { RecordingClient.new }
  let(:dir) { Dir.mktmpdir }
  let(:log_path) { File.join(dir, "reaped.log") }
  let(:store) { ClaudeInbox::Store.new(path: nil, clock: -> { now }) }
  let(:reaper) { described_class.new(client, store, log_path: log_path) }

  after { FileUtils.remove_entry(dir) if Dir.exist?(dir) }

  it "removes the sessions that are due, forgets them, and logs each one" do
    sessions = [session(id: "old1", state: "done", started_at: Time.at(quiet_since)), session(id: "old2", state: "done", started_at: Time.at(quiet_since), name: "auth spike")]
    store.update(sessions)

    expect(reaper.sweep(sessions, now).sort).to eq(%w[old1 old2])
    expect(client.removed.sort).to eq(%w[old1 old2])
    expect(store.entry("old1")).to be_nil
    expect(store.entry("old2")).to be_nil
    expect(File.read(log_path).lines.size).to eq(2)
    expect(File.read(log_path)).to include("idle 15d")
    expect(File.read(log_path)).to include("\"auth spike\"")
    expect(File.read(log_path)).to include("reaped")
  end

  it "names what it is about to take without taking anything" do
    sessions = [session(id: "old1", state: "done", started_at: Time.at(quiet_since)), session(id: "busy", state: "working")]
    store.update(sessions)

    expect(reaper.due(sessions, now)).to eq(%w[old1])
    expect(client.removed).to be_empty
    expect(store.entry("old1")).not_to be_nil
    expect(File.exist?(log_path)).to be(false)
    expect(described_class.disabled.due(sessions, now)).to be_empty
  end

  it "leaves a session that has not been quiet long enough, and writes no log at all" do
    sessions = [session(id: "fresh", state: "done")]

    store.update(sessions)
    expect(reaper.sweep(sessions, now)).to be_empty
    expect(client.removed).to be_empty
    expect(File.exist?(log_path)).to be(false)
  end

  it "dates idleness from the last state change, not from when the session started" do
    long_run = session(id: "long", state: "working", started_at: Time.at(quiet_since))
    store.update([long_run])
    just_finished = session(id: "long", state: "done", started_at: Time.at(quiet_since))
    store.update([just_finished])

    expect(reaper.sweep([just_finished], now)).to be_empty
    expect(client.removed).to be_empty
  end

  it "keeps a session whose worktree refuses, and carries on with the rest" do
    sessions = [session(id: "unpushed", state: "done", started_at: Time.at(quiet_since)), session(id: "clean", state: "done", started_at: Time.at(quiet_since))]
    store.update(sessions)

    reaper = described_class.new(RecordingClient.new(refuse: %w[unpushed]), store, log_path: log_path)
    expect(reaper.sweep(sessions, now)).to eq(%w[clean])
    expect(store.entry("unpushed")["reap_failed_at"]).to eq(now.to_i)
    expect(store.entry("unpushed")["reap_error"]).to include("unpushed commits")
    expect(store.entry("clean")).to be_nil
    expect(File.read(log_path)).to include("kept — rm failed: worktree has unpushed commits")
  end

  it "backs off a refused session for RETRY_AFTER, then tries once more" do
    sessions = [session(id: "unpushed", state: "done", started_at: Time.at(quiet_since))]
    store.update(sessions)
    refusing = RecordingClient.new(refuse: %w[unpushed])
    reaper = described_class.new(refusing, store, log_path: log_path)

    reaper.sweep(sessions, now)
    expect(reaper.sweep(sessions, now + described_class::RETRY_AFTER - 60)).to be_empty
    expect(File.read(log_path).lines.size).to eq(1)

    reaper.sweep(sessions, now + described_class::RETRY_AFTER + 60)
    expect(File.read(log_path).lines.size).to eq(2)
  end

  it "refuses to reap anything it cannot write an audit line for" do
    File.write(File.join(dir, "blocked"), "not a directory")
    sessions = [session(id: "old1", state: "done", started_at: Time.at(quiet_since))]
    store.update(sessions)
    reaper = described_class.new(client, store, log_path: File.join(dir, "blocked", "reaped.log"))

    expect { reaper.sweep(sessions, now) }.to raise_error(SystemCallError)
    expect(client.removed).to be_empty
    expect(store.entry("old1")).not_to be_nil
  end

  it "words what it took for the notice, and says where the log is" do
    reaper = described_class.new(client, nil, log_path: log_path)

    expect(reaper.report(%w[old1])).to eq("reaped 1 session idle over 14d — see #{log_path}")
    expect(reaper.report(%w[old1 old2])).to eq("reaped 2 sessions idle over 14d — see #{log_path}")
  end

  it "does nothing at all when disabled" do
    sessions = [session(id: "old1", state: "done", started_at: Time.at(quiet_since))]
    expect(described_class.disabled.sweep(sessions, now)).to be_empty
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
