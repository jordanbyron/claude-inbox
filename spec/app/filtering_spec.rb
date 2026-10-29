# frozen_string_literal: true

RSpec.describe ClaudeInbox::App do
  let(:terminal) { ScreenTerminal.new }

  let(:client) { RecordingClient.new }
  let(:store) { ClaudeInbox::Store.new(path: nil) }
  let(:pull_requests) { ClaudeInbox::PullRequests.new(cache_path: nil, resolved_path: nil, gh: nil) }
  let(:queue) { Queue.new }

  let(:app) { build_app(client:, store:, pull_requests:, queue:, terminal:) }

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

  it "finds the session behind a pull request linked by hand" do
    app # built first, so this store update is not the one build_app overwrites
    store.set_pr("f23c8673", "https://github.com/o/r/pull/4242")
    store.update(pull_requests.enrich(client.list, store.pr_overrides))
    press(app, "/", "#", "4", "2", "4", "2")
    expect(app).to paint("comma3x not booting")
    expect(app).not_to paint("sensor token resilience test")
  end
end
