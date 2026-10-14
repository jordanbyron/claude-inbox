# frozen_string_literal: true

RSpec.describe ClaudeInbox::App do
  let(:terminal) { ScreenTerminal.new }

  let(:client) { RecordingClient.new }
  let(:store) { ClaudeInbox::Store.new(path: nil) }
  let(:pull_requests) { ClaudeInbox::PullRequests.new(cache_path: nil, resolved_path: nil, gh: nil) }
  let(:queue) { Queue.new }

  let(:app) { build_app(client:, store:, pull_requests:, queue:, terminal:) }

  after { client.release }

  describe "alias and pull request editors" do
    it "seed their buffer from the store, so reopening shows what was saved" do
      store.set_alias("f23c8673", "auth spike")
      store.set_pr("f23c8673", "https://github.com/o/r/pull/7")

      press(app, "a")
      expect(app).to paint("> auth spike")
      press(app, "\e", "P")
      expect(app).to paint("> https://github.com/o/r/pull/7")
    end
  end
end
