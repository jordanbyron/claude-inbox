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

  let(:opened) { [] }
  let(:stack) do
    [190, 191, 192].map do |n|
      ClaudeInbox::PullRequest.new(number: n, url: "https://github.com/o/r/pull/#{n}", state: "OPEN",
        health: (n == 191) ? "FAILING" : nil)
    end
  end
  let(:link) { ->(prs) { store.update(store.sessions.map { |s| (s.id == "f23c8673") ? s.with(prs: prs) : s }) } }

  describe "o" do
    before do
      app
      allow(ClaudeInbox::Subprocess).to receive(:capture) { |*args| opened << args.last }
    end

    it "opens a lone pull request straight away" do
      link.call(stack.first(1))
      press(app, "o")
      expect(screen(app).first).to include("opening #190")
      expect(wait_for { opened.any? }).to be(true)
      expect(opened).to eq(["https://github.com/o/r/pull/190"])
    end

    it "asks which of several, and o again opens the headline" do
      link.call(stack)
      press(app, "o")
      expect(screen(app).join("\n")).to include("1  #191 open · ✗ checks")
      press(app, "o")
      expect(wait_for { opened.any? }).to be(true)
      expect(opened).to eq(["https://github.com/o/r/pull/191"])
      expect(screen(app).join("\n")).not_to include("Open pull request")
    end

    it "opens the nth on a digit, or nothing on esc" do
      link.call(stack)
      press(app, "o", "3")
      expect(wait_for { opened.any? }).to be(true)
      expect(opened).to eq(["https://github.com/o/r/pull/192"])
      press(app, "o", "\e")
      expect(screen(app).join("\n")).not_to include("Open pull request")
      expect(opened.size).to eq(1)
    end
  end

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

    it "asks which of several, and y again copies the headline" do
      link.call(stack)
      press(app, "y")
      expect(screen(app).join("\n")).to include("Copy pull request")
      press(app, "y")
      expect(wait_for { screen(app).first.include?("copied #191") }).to be(true)
      expect(copied).to eq(["https://github.com/o/r/pull/191"])
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
