# frozen_string_literal: true

RSpec.describe ClaudeInbox::App do
  let(:terminal) { ScreenTerminal.new }

  let(:client) { RecordingClient.new }
  let(:store) { ClaudeInbox::Store.new(path: nil) }
  let(:pull_requests) { ClaudeInbox::PullRequests.new(cache_path: nil, resolved_path: nil, gh: nil) }
  let(:queue) { Queue.new }

  let(:app) { build_app(client:, store:, pull_requests:, queue:, terminal:) }

  after { client.release }

  describe "snooze by typing" do
    it "opens a prompt on 5 and snoozes until the time typed" do
      press(app, "s", "5")
      expect(app).to paint("Wake at (")
      press(app, "2", "h")
      press(app, "\r")
      expect(app).not_to paint("Wake at (")
      expect(store.entry("f23c8673")["wake_at"]).to be_within(5).of(Time.now.to_i + 7200)
    end

    it "keeps the prompt up and says what it takes when the text means nothing" do
      press(app, "s", "5")
      press(app, *"later".chars)
      press(app, "\r")
      expect(app).to paint("try 45m, 2h, 3d").in_status_line
      expect(app).to paint("> later")
      expect(store.entry("f23c8673")).not_to include("wake_at")
      press(app, "\e")
      expect(app).not_to paint("Wake at (")
    end
  end

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
