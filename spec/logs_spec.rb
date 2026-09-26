# frozen_string_literal: true

require_relative "../lib/claude_inbox/logs"

RSpec.describe ClaudeInbox::Logs do
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
    expect(wait_for { logs.cached(id) }).to eq(lines)
  end

  it "knows nothing until asked, then answers from the cache" do
    expect(logs.cached("abc12345")).to be_nil
    logs.want("abc12345")
    @elapsed += ClaudeInbox::Logs::DEBOUNCE
    logs.tick
    settle("abc12345")
    expect(client.asked).to eq(%w[abc12345])
  end

  it "waits out the debounce before asking" do
    logs.want("abc12345")
    logs.tick
    expect(logs.cached("abc12345")).to be_nil
    expect(client.asked).to be_empty
  end

  it "only keeps the latest request" do
    logs.want("abc12345")
    logs.want("f23c8673")
    @elapsed += ClaudeInbox::Logs::DEBOUNCE
    logs.tick
    settle("f23c8673")
    expect(logs.cached("abc12345")).to be_nil
    expect(client.asked).to eq(%w[f23c8673])
  end

  it "does not ask again while the cache is fresh" do
    logs.want("abc12345")
    @elapsed += ClaudeInbox::Logs::DEBOUNCE
    logs.tick
    settle("abc12345")
    logs.want("abc12345")
    @elapsed += ClaudeInbox::Logs::DEBOUNCE
    logs.tick
    expect(settled_asked).to eq(%w[abc12345])
  end

  it "ignores a request with nothing to fetch" do
    logs.want(nil)
    @elapsed += ClaudeInbox::Logs::DEBOUNCE
    logs.tick
    expect(settled_asked).to be_empty
  end
end
