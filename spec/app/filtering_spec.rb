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

  it "edits the filter line in the middle, and closes it on a backspace from empty" do
    press(app, "/", "ac", "\e[D", "b")
    expect(app).to paint("/abc").in_footer
    press(app, "\x01", "q")
    expect(app).to paint("/qabc").in_footer
    press(app, "\x05", "\x7f", "\x7f", "\x7f", "\x7f")
    expect(screen(app).last.strip).to eq("/")
    press(app, "\x7f")
    expect(app).to paint("j/k move").in_footer
  end
end
