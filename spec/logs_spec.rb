# frozen_string_literal: true

RSpec.describe ClaudeInbox::Logs do
  let(:replay) { (1..10).map { |i| "line #{i}" }.join("\r\n") }
  let(:client) { ClaudeInbox::FixtureClient.new(fixture_path("agents.json"), logs: replay) }
  let(:asked) { [] }
  let(:now) { Time.at(1_789_400_000) }
  let(:clock) { StillClock.new(now) }
  let(:logs) { described_class.new(client, clock: clock) }
  let(:lines) { (1..10).map { |i| "line #{i}" } }

  before do
    allow(client).to receive(:logs).and_wrap_original do |original, id|
      asked << id
      original.call(id)
    end
    logs.start
  end
  after { logs.stop }

  it "knows nothing until asked, then answers from the cache" do
    expect(logs.cached("abc12345")).to be_nil
    logs.want("abc12345")
    clock.advance(described_class::DEBOUNCE)
    logs.tick
    expect(logs).to cache_eventually("abc12345", lines)
    expect(asked).to eq(%w[abc12345])
  end

  it "waits out the debounce before asking" do
    logs.want("abc12345")
    logs.tick
    expect(logs.cached("abc12345")).to be_nil
    expect(asked).to be_empty
  end

  it "only keeps the latest request" do
    logs.want("abc12345")
    logs.want("f23c8673")
    clock.advance(described_class::DEBOUNCE)
    logs.tick
    expect(logs).to cache_eventually("f23c8673", lines)
    expect(logs.cached("abc12345")).to be_nil
    expect(asked).to eq(%w[f23c8673])
  end

  it "does not ask again while the cache is fresh" do
    logs.want("abc12345")
    clock.advance(described_class::DEBOUNCE)
    logs.tick
    expect(logs).to cache_eventually("abc12345", lines)
    logs.want("abc12345")
    clock.advance(described_class::DEBOUNCE)
    logs.tick
    sleep 0.05 # time for the worker to make any request it was going to
    expect(asked).to eq(%w[abc12345])
  end

  it "ignores a request with nothing to fetch" do
    logs.want(nil)
    clock.advance(described_class::DEBOUNCE)
    logs.tick
    sleep 0.05
    expect(asked).to be_empty
  end
end
