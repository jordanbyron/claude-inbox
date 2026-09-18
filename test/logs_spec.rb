# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/claude_inbox/logs"

describe ClaudeInbox::Logs do
  let(:queue) { Queue.new }
  let(:replay) { (1..10).map { |i| "line #{i}" }.join("\r\n") }
  let(:client) { ClaudeInbox::FixtureClient.new(fixture_path("agents.json"), logs: replay) }
  let(:now) { Time.at(1_789_400_000) }
  let(:clock) { -> { now + @elapsed } }
  let(:logs) { ClaudeInbox::Logs.new(client, queue, clock: clock) }
  let(:lines) { (1..10).map { |i| "line #{i}" } }

  before { @elapsed = 0 }
  after { logs.stop }

  it "knows nothing until asked, then answers on the queue and from the cache" do
    _(logs.cached("abc12345")).must_be_nil
    logs.want("abc12345")
    @elapsed += ClaudeInbox::Logs::DEBOUNCE
    logs.tick
    _(queue.pop).must_equal [:peek, "abc12345", lines]
    _(logs.cached("abc12345")).must_equal lines
  end

  it "waits out the debounce before asking" do
    logs.want("abc12345")
    logs.tick
    _(queue).must_be_empty
  end

  it "only keeps the latest request" do
    logs.want("abc12345")
    logs.want("f23c8673")
    @elapsed += ClaudeInbox::Logs::DEBOUNCE
    logs.tick
    _(queue.pop[1]).must_equal "f23c8673"
    _(queue).must_be_empty
  end

  it "does not ask again while the cache is fresh" do
    logs.want("abc12345")
    @elapsed += ClaudeInbox::Logs::DEBOUNCE
    logs.tick
    queue.pop
    logs.want("abc12345")
    @elapsed += ClaudeInbox::Logs::DEBOUNCE
    logs.tick
    _(queue).must_be_empty
  end

  it "ignores a request with nothing to fetch" do
    logs.want(nil)
    @elapsed += ClaudeInbox::Logs::DEBOUNCE
    logs.tick
    _(queue).must_be_empty
  end
end
