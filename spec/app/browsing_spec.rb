# frozen_string_literal: true

RSpec.describe ClaudeInbox::App do
  let(:terminal) { ScreenTerminal.new }

  let(:client) { RecordingClient.new }
  let(:store) { ClaudeInbox::Store.new(path: nil) }
  let(:pull_requests) { ClaudeInbox::PullRequests.new(cache_path: nil, resolved_path: nil, gh: nil) }
  let(:queue) { Queue.new }
  let(:copied) { [] }
  let(:clipboard) { ->(text) { copied << text } }

  let(:app) { build_app(client:, store:, pull_requests:, queue:, terminal:, clipboard: clipboard) }

  after { client.release }

  describe "y" do
    # Built first, so an example's own store update is not the one build_app overwrites.
    before { app }

    it "copies a pull request linked by hand before anything else" do
      store.set_pr("f23c8673", "https://github.com/o/r/pull/7")
      press(app, "y")
      expect(wait_for { screen(app).first.include?("copied #7") }).to be(true)
      expect(copied).to eq(["https://github.com/o/r/pull/7"])
    end

    it "copies the scanned pull request" do
      press(app, "j", "j", "j", "j", "y")
      expect(wait_for { screen(app).first.include?("copied #885") }).to be(true)
      expect(copied).to eq(["https://github.com/jordanbyron/parks_genie/pull/885"])
    end

    it "copies the claude.ai/code address when there is no pull request" do
      store.update(store.sessions.map { |s| (s.id == "f23c8673") ? s.with(bridge_id: "cse_abc") : s })
      press(app, "y")
      expect(wait_for { screen(app).first.include?("copied https://claude.ai/code/session_abc") }).to be(true)
      expect(copied).to eq(["https://claude.ai/code/session_abc"])
    end

    it "copies the session id when it has neither" do
      press(app, "y")
      expect(wait_for { screen(app).first.include?("copied f23c8673") }).to be(true)
      expect(copied).to eq(["f23c8673"])
    end

    context "without a clipboard tool" do
      let(:clipboard) { ->(_) { false } }

      it "says so" do
        press(app, "y")
        expect(wait_for { screen(app).first.include?("no clipboard tool found") }).to be(true)
      end
    end
  end
end
