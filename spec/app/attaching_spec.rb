# frozen_string_literal: true

require "stringio"

RSpec.describe ClaudeInbox::App do
  let(:terminal) { ScreenTerminal.new }

  let(:client) { RecordingClient.new }
  let(:store) { ClaudeInbox::Store.new(path: nil) }
  let(:pull_requests) { ClaudeInbox::PullRequests.new(cache_path: nil, resolved_path: nil, gh: nil) }
  let(:queue) { Queue.new }

  let(:app) do
    described_class.new(
      client: client, store: store, pull_requests: pull_requests,
      rate_limits: ClaudeInbox::RateLimits.new(path: fixture_path("rate_limits.json")),
      terminal: terminal, input: StringIO.new, color: false, queue: queue
    )
  end

  before do
    store.update(ClaudeInbox::Sessions.load(client: client, pull_requests: pull_requests, overrides: {}))
    app.step
  end

  after { client.release }

  describe "adopting a remote session" do
    let(:client) { RecordingClient.new(origins: {57405 => :remote}) }

    before { allow(client).to receive(:adopt).and_call_original }

    it "asks on Enter, then pulls the conversation in and attaches to it" do
      press(app, "\t", "\r")
      expect(app).to paint("Pull this session into the daemon?")
      expect(client).not_to have_received(:adopt)

      press(app, "y")
      expect(wait_for {
        app.step
        client.attached == %w[adop7ed0]
      }).to be(true)
      expect(client).to have_received(:adopt).once.with(session_id: "4a93393d-1c06-57da-9fb8-12f5b1535d95", cwd: "/Users/byron/code/claude-inbox", pid: 57405)
    end

    it "leaves it alone when dismissed" do
      press(app, "\t", "\r", "\e")
      expect(app).not_to paint("Pull this session")
      expect(client).not_to have_received(:adopt)
    end
  end
end
