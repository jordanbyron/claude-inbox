# frozen_string_literal: true

RSpec.describe ClaudeInbox::App do
  let(:terminal) { ScreenTerminal.new }

  let(:client) { RecordingClient.new }
  let(:store) { ClaudeInbox::Store.new(path: nil) }
  let(:pull_requests) { ClaudeInbox::PullRequests.new(cache_path: nil, resolved_path: nil, gh: nil) }
  let(:queue) { Queue.new }

  let(:app) { build_app(client:, store:, pull_requests:, queue:, terminal:) }

  after { client.release }

  describe "the cursor after a row leaves the list" do
    it "lands on the row below the one settled" do
      press(app, "j", "j", "j")
      expect(app).to paint("trailforks skill handoff").on_selected_row
      press(app, "x")
      expect(app).to paint("sensor token resilience test").on_selected_row
    end

    it "lands on the row above when the last one is settled" do
      press(app, "G", "x")
      expect(app).to paint("github milestone review").on_selected_row
    end

    it "lands on the row below the one snoozed from the menu" do
      press(app, "j", "j", "j", "s", "2")
      expect(app).to paint("sensor token resilience test").on_selected_row
    end

    it "lands on the row below the one snoozed until a typed time" do
      press(app, "j", "j", "j", "s", "5", "2", "h", "\r")
      expect(app).to paint("sensor token resilience test").on_selected_row
    end

    it "stays put when the snooze menu is closed without a choice" do
      press(app, "j", "j", "j", "s", "\e")
      expect(app).to paint("trailforks skill handoff").on_selected_row
    end
  end

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

  describe "a title from claude" do
    let(:titler) { instance_double(ClaudeInbox::Titler, title: "comma3x boot loop") }
    let(:app) { build_app(client:, store:, pull_requests:, queue:, terminal:, titler: titler) }

    it "asks for the selected row by its prompt and current label, and keeps the answer as the alias" do
      press(app, "r")
      expect(wait_for { store.alias_for("f23c8673") == "comma3x boot loop" }).to be(true)
      expect(titler).to have_received(:title).with(having_attributes(id: "f23c8673"), current: "comma3x not booting")
      expect(app).to paint("comma3x boot loop").on_selected_row
      expect(app).to paint("titled “comma3x boot loop” — a edits it").in_status_line
    end

    it "asks with the alias as the current label once one is set" do
      store.set_alias("f23c8673", "auth spike")
      press(app, "r")
      expect(wait_for { store.alias_for("f23c8673") == "comma3x boot loop" }).to be(true)
      expect(titler).to have_received(:title).with(anything, current: "auth spike")
    end

    it "keeps a title claude hands back unchanged, and says so" do
      allow(titler).to receive(:title).and_return("comma3x not booting")
      press(app, "r")
      expect(wait_for { screen(app).any? { |l| l.include?("still fits") } }).to be(true)
      expect(app).to paint("“comma3x not booting” still fits").in_status_line
      expect(store.alias_for("f23c8673")).to be_nil
    end

    it "says why when claude gives no title, and leaves the label alone" do
      allow(titler).to receive(:title).and_raise(ClaudeInbox::Titler::Error, "claude -p failed: Not logged in")
      press(app, "r")
      expect(wait_for { screen(app).any? { |l| l.include?("Not logged in") } }).to be(true)
      expect(app).to paint("claude -p failed: Not logged in").in_status_line
      expect(store.alias_for("f23c8673")).to be_nil
    end
  end
end
