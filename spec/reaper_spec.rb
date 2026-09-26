# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeInbox::Reaper, :reaper do
  let(:now) { Time.at(1_789_600_000) }
  let(:quiet_since) { now.to_i - ClaudeInbox::Store::REAP_AFTER - 86_400 }
  let(:client) { RecordingClient.new }
  let(:dir) { Dir.mktmpdir }
  let(:log_path) { File.join(dir, "reaped.log") }

  after { FileUtils.remove_entry(dir) if Dir.exist?(dir) }

  it "removes the sessions that are due, forgets them, and logs each one" do
    sessions = [quiet_session("old1"), quiet_session("old2", name: "auth spike")]
    store = store_for(sessions)

    expect(sweep(store, sessions).sort).to eq(%w[old1 old2])
    expect(client.removed.sort).to eq(%w[old1 old2])
    expect(store.entry("old1")).to be_nil
    expect(store.entry("old2")).to be_nil
    expect(log.lines.size).to eq(2)
    expect(log).to include("idle 15d")
    expect(log).to include("\"auth spike\"")
    expect(log).to include("reaped")
  end

  it "names what it is about to take without taking anything" do
    sessions = [quiet_session("old1"), session(id: "busy", state: "working")]
    store = store_for(sessions)
    reaper = described_class.new(client, store, log_path: log_path)

    expect(reaper.due(sessions, now)).to eq(%w[old1])
    expect(client.removed).to be_empty
    expect(store.entry("old1")).not_to be_nil
    expect(log).to eq("")
    expect(described_class.disabled.due(sessions, now)).to be_empty
  end

  it "leaves a session that has not been quiet long enough, and writes no log at all" do
    sessions = [session(id: "fresh", state: "done")]

    expect(sweep(store_for(sessions), sessions)).to be_empty
    expect(client.removed).to be_empty
    expect(File.exist?(log_path)).to be(false)
  end

  it "dates idleness from the last state change, not from when the session started" do
    long_run = session(id: "long", state: "working", started_at: Time.at(quiet_since))
    store = store_for([long_run])
    just_finished = session(id: "long", state: "done", started_at: Time.at(quiet_since))
    store.update([just_finished])

    expect(sweep(store, [just_finished])).to be_empty
    expect(client.removed).to be_empty
  end

  it "keeps a session whose worktree refuses, and carries on with the rest" do
    sessions = [quiet_session("unpushed"), quiet_session("clean")]
    store = store_for(sessions)

    reaper = described_class.new(RecordingClient.new(refuse: %w[unpushed]), store, log_path: log_path)
    expect(reaper.sweep(sessions, now)).to eq(%w[clean])
    expect(store.entry("unpushed")["reap_failed_at"]).to eq(now.to_i)
    expect(store.entry("unpushed")["reap_error"]).to include("unpushed commits")
    expect(store.entry("clean")).to be_nil
    expect(log).to include("kept — rm failed: worktree has unpushed commits")
  end

  it "backs off a refused session for RETRY_AFTER, then tries once more" do
    sessions = [quiet_session("unpushed")]
    store = store_for(sessions)
    refusing = RecordingClient.new(refuse: %w[unpushed])
    reaper = described_class.new(refusing, store, log_path: log_path)

    reaper.sweep(sessions, now)
    expect(reaper.sweep(sessions, now + described_class::RETRY_AFTER - 60)).to be_empty
    expect(log.lines.size).to eq(1)

    reaper.sweep(sessions, now + described_class::RETRY_AFTER + 60)
    expect(log.lines.size).to eq(2)
  end

  it "refuses to reap anything it cannot write an audit line for" do
    File.write(File.join(dir, "blocked"), "not a directory")
    sessions = [quiet_session("old1")]
    store = store_for(sessions)
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
    sessions = [quiet_session("old1")]
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
