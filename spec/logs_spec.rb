# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/claude_inbox/logs"

describe ClaudeInbox::Logs do
  let(:replay) { (1..10).map { |i| "line #{i}" }.join("\r\n") }
  let(:client) do
    Class.new(ClaudeInbox::FixtureClient) {
      def asked = (@asked ||= [])

      def logs(id)
        asked << id
        super
      end
    }.new(fixture_path("agents.json"), logs: replay)
  end
  let(:now) { Time.at(1_789_400_000) }
  let(:clock) { -> { now + @elapsed } }
  let(:logs) { ClaudeInbox::Logs.new(client, clock: clock) }
  let(:lines) { (1..10).map { |i| "line #{i}" } }

  before do
    @elapsed = 0
    logs.start
  end
  after { logs.stop }

  def settled_asked = (sleep 0.05
                       client.asked)

  def settle(id)
    _(wait_for { logs.cached(id) }).must_equal lines
  end

  it "knows nothing until asked, then answers from the cache" do
    _(logs.cached("abc12345")).must_be_nil
    logs.want("abc12345")
    @elapsed += ClaudeInbox::Logs::DEBOUNCE
    logs.tick
    settle("abc12345")
    _(client.asked).must_equal %w[abc12345]
  end

  it "waits out the debounce before asking" do
    logs.want("abc12345")
    logs.tick
    _(logs.cached("abc12345")).must_be_nil
    _(client.asked).must_be_empty
  end

  it "only keeps the latest request" do
    logs.want("abc12345")
    logs.want("f23c8673")
    @elapsed += ClaudeInbox::Logs::DEBOUNCE
    logs.tick
    settle("f23c8673")
    _(logs.cached("abc12345")).must_be_nil
    _(client.asked).must_equal %w[f23c8673]
  end

  it "does not ask again while the cache is fresh" do
    logs.want("abc12345")
    @elapsed += ClaudeInbox::Logs::DEBOUNCE
    logs.tick
    settle("abc12345")
    logs.want("abc12345")
    @elapsed += ClaudeInbox::Logs::DEBOUNCE
    logs.tick
    _(settled_asked).must_equal %w[abc12345]
  end

  it "ignores a request with nothing to fetch" do
    logs.want(nil)
    @elapsed += ClaudeInbox::Logs::DEBOUNCE
    logs.tick
    _(settled_asked).must_be_empty
  end
end
