# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/claude_inbox/server"
require "stringio"

describe ClaudeInbox::Server do
  let(:out) { StringIO.new }
  let(:store) { ClaudeInbox::Store.new(path: nil) }
  let(:client) { ClaudeInbox::FixtureClient.new(fixture_path("agents.json"), logs: "hello\r\nworld") }
  let(:queue) { server.instance_variable_get(:@queue) }

  let(:server) do
    ClaudeInbox::Server.new(
      client: client, store: store, jobs_dir: fixture_path("jobs"),
      pull_requests: ClaudeInbox::PullRequests.new(cache_path: nil, resolved_path: nil, gh: nil),
      out: out, input: StringIO.new
    )
  end

  def events = out.string.lines.map { |l| JSON.parse(l) }

  def sections = events.reverse.find { |e| e["event"] == "sections" }["sections"].to_h { |s| [s["name"], s["rows"]] }

  def polled
    server.instance_variable_get(:@poller).once
    server.drain(queue.pop)
  end

  it "publishes the sections after a poll, one row per session, placed by the store" do
    polled
    _(events.map { |e| e["event"] }).must_equal %w[polled sections]
    _(sections.keys).must_equal %w[pinned needs_you active snoozed settled]
    _(sections["needs_you"].map { |r| r["id"] }).must_include "f23c8673"
    row = sections["active"].find { |r| r["id"] == "b0b18338" }
    _(row["color"]).must_equal "orange"
    _(row["selectable"]).must_equal true
  end

  it "answers a command with the sections it left behind" do
    polled
    server.command("cmd" => "snooze", "id" => "f23c8673", "choice" => "h1")
    _(sections["snoozed"].map { |r| r["id"] }).must_equal ["f23c8673"]
    _(sections["snoozed"][0]["wake_at"]).must_be_kind_of Integer
  end

  it "refuses a pull request link that is not a github url" do
    server.command("cmd" => "set_pr", "id" => "f23c8673", "value" => "nope")
    _(events.last["event"]).must_equal "error"
    _(store.pr_for("f23c8673")).must_be_nil
  end

  it "reports what it does not understand instead of dying" do
    server.command("cmd" => "dance")
    _(events.last["message"]).must_include "dance"
  end

  it "hands peeked logs over as lines" do
    t = Time.now
    logs = ClaudeInbox::Logs.new(client, queue, clock: -> { t += 1 })
    server.instance_variable_set(:@logs, logs)
    server.command("cmd" => "peek", "id" => "f23c8673")
    logs.tick
    server.drain(queue.pop)
    peek = events.find { |e| e["event"] == "peek" }
    _(peek["id"]).must_equal "f23c8673"
    _(peek["lines"]).must_equal %w[hello world]
  end
end
