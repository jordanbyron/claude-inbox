# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

Reaper = ClaudeInbox::Reaper

# Stands in for `claude rm`: records what it took, and refuses the ids it was
# told to, the way the real thing refuses a worktree holding unpushed commits.
class RecordingClient < ClaudeInbox::AgentsClient
  attr_reader :removed

  def initialize(refuse: [])
    super()
    @refuse = refuse
    @removed = []
  end

  def rm(id)
    raise ClaudeInbox::AgentsClient::Error, "rm failed: worktree has unpushed commits" if @refuse.include?(id)
    @removed << id
    true
  end
end

describe Reaper do
  let(:now) { Time.at(1_789_600_000) }
  let(:quiet_since) { now.to_i - ClaudeInbox::Store::REAP_AFTER - 86_400 }
  let(:client) { RecordingClient.new }
  let(:dir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(dir) if Dir.exist?(dir) }

  # merge_entries dates a finished session with no process from `started_at`,
  # so an old `started_at` is the whole of the setup needed to look long idle.
  def quiet_session(id, **attrs) = session(id: id, state: "done", started_at: Time.at(quiet_since), **attrs)

  def store_for(sessions)
    store = ClaudeInbox::Store.new(path: nil, clock: -> { now })
    store.update(sessions)
    store
  end

  def log_path = File.join(dir, "reaped.log")

  def log = File.exist?(log_path) ? File.read(log_path) : ""

  def sweep(store, sessions, at: now) = Reaper.new(client, store, log_path: log_path).sweep(sessions, at)

  it "removes the sessions that are due, forgets them, and logs each one" do
    sessions = [quiet_session("old1"), quiet_session("old2", name: "auth spike")]
    store = store_for(sessions)

    _(sweep(store, sessions).sort).must_equal %w[old1 old2]
    _(client.removed.sort).must_equal %w[old1 old2]
    _(store.entry("old1")).must_be_nil
    _(store.entry("old2")).must_be_nil
    _(log.lines.size).must_equal 2
    _(log).must_include "idle 15d"
    _(log).must_include "\"auth spike\""
    _(log).must_include "reaped"
  end

  it "leaves a session that has not been quiet long enough, and writes no log at all" do
    sessions = [session(id: "fresh", state: "done")]

    _(sweep(store_for(sessions), sessions)).must_be_empty
    _(client.removed).must_be_empty
    _(File.exist?(log_path)).must_equal false
  end

  it "dates idleness from the last state change, not from when the session started" do
    long_run = session(id: "long", state: "working", started_at: Time.at(quiet_since))
    store = store_for([long_run])
    just_finished = session(id: "long", state: "done", started_at: Time.at(quiet_since))
    store.update([just_finished])

    _(sweep(store, [just_finished])).must_be_empty
    _(client.removed).must_be_empty
  end

  it "keeps a session whose worktree refuses, and carries on with the rest" do
    sessions = [quiet_session("unpushed"), quiet_session("clean")]
    store = store_for(sessions)

    reaper = Reaper.new(RecordingClient.new(refuse: %w[unpushed]), store, log_path: log_path)
    _(reaper.sweep(sessions, now)).must_equal %w[clean]
    _(store.entry("unpushed")["reap_failed_at"]).must_equal now.to_i
    _(store.entry("unpushed")["reap_error"]).must_include "unpushed commits"
    _(store.entry("clean")).must_be_nil
    _(log).must_include "kept — rm failed: worktree has unpushed commits"
  end

  it "backs off a refused session for RETRY_AFTER, then tries once more" do
    sessions = [quiet_session("unpushed")]
    store = store_for(sessions)
    refusing = RecordingClient.new(refuse: %w[unpushed])
    reaper = Reaper.new(refusing, store, log_path: log_path)

    reaper.sweep(sessions, now)
    _(reaper.sweep(sessions, now + Reaper::RETRY_AFTER - 60)).must_be_empty
    _(log.lines.size).must_equal 1

    reaper.sweep(sessions, now + Reaper::RETRY_AFTER + 60)
    _(log.lines.size).must_equal 2
  end

  it "refuses to reap anything it cannot write an audit line for" do
    File.write(File.join(dir, "blocked"), "not a directory")
    sessions = [quiet_session("old1")]
    store = store_for(sessions)
    reaper = Reaper.new(client, store, log_path: File.join(dir, "blocked", "reaped.log"))

    _ { reaper.sweep(sessions, now) }.must_raise SystemCallError
    _(client.removed).must_be_empty
    _(store.entry("old1")).wont_be_nil
  end

  it "does nothing at all when disabled" do
    sessions = [quiet_session("old1")]
    _(Reaper.disabled.sweep(sessions, now)).must_be_empty
  end

  it "reads CLAUDE_INBOX_NO_REAP as the off switch" do
    original = ENV["CLAUDE_INBOX_NO_REAP"]
    ENV["CLAUDE_INBOX_NO_REAP"] = "1"
    _(Reaper.enabled?).must_equal false
    ENV["CLAUDE_INBOX_NO_REAP"] = ""
    _(Reaper.enabled?).must_equal true
  ensure
    ENV["CLAUDE_INBOX_NO_REAP"] = original
  end
end
