# frozen_string_literal: true

require "stringio"

RSpec.describe ClaudeInbox::App do
  let(:ctrl_x) { "\x18" }

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

  describe "ctrl-x deletes a session" do
    it "asks first and deletes once confirmed" do
      press(app, ctrl_x)
      expect(app).to paint("Delete session f23c8673?")
      expect(client.removed).to be_empty

      press(app, "y")
      expect(wait_for { client.removed == %w[f23c8673] }).to be(true)
      expect(wait_for { store.entry("f23c8673").nil? }).to be(true)
      expect(app).not_to paint("comma3x not booting")
    end

    it "keeps the session when the confirm is dismissed" do
      ["\e", "n", "q"].each do |dismiss|
        press(app, ctrl_x, dismiss)
        expect(app).not_to paint("Delete session")
        expect(client.removed).to be_empty
      end
    end

    it "refuses on a terminal row instead of arming a confirm it can't honour" do
      press(app, "\t", ctrl_x)
      expect(app).not_to paint("Delete session")
      expect(app).to paint("terminal").in_status_line
    end

    # Waiting for the stop to land is what makes "nothing was deleted" mean
    # anything: the action runs on a thread, so asserting it straight away
    # passes no matter which way the key was routed.
    it "still stops rather than deletes on X, sharing the one confirm" do
      press(app, "X")
      expect(app).to paint("Stop session f23c8673?")

      press(app, "y")
      expect(wait_for { client.stopped == %w[f23c8673] }).to be(true)
      expect(client.removed).to be_empty
      expect(store.entry("f23c8673")).not_to be_nil
    end
  end

  describe "deleting a session" do
    it "says so while the worker runs, then confirms once it is gone" do
      client.hold
      press(app, ctrl_x, "y")
      expect(app).to paint("deleting f23c8673…").in_status_line

      client.release
      expect(wait_for { screen(app).first.include?("deleted f23c8673") }).to be(true)
    end
  end
end
