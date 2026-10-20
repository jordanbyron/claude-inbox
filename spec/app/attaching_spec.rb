# frozen_string_literal: true

RSpec.describe ClaudeInbox::App do
  let(:ctrl_x) { "\x18" }

  let(:terminal) { ScreenTerminal.new }

  let(:client) { RecordingClient.new }
  let(:store) { ClaudeInbox::Store.new(path: nil) }
  let(:pull_requests) { ClaudeInbox::PullRequests.new(cache_path: nil, resolved_path: nil, gh: nil) }
  let(:queue) { Queue.new }

  let(:app) { build_app(client:, store:, pull_requests:, queue:, terminal:) }

  after { client.release }

  describe "attaching" do
    it "records the visit, so the row no longer reads as unread" do
      app
      expect(store.sections.needs_you.map(&:unread?)).to eq([true])
      press(app, "\r")
      expect(client.attached).to eq(%w[f23c8673])
      expect(store.entry("f23c8673")["last_visited_at"]).to eq(store.entry("f23c8673")["acknowledged_at"])
      expect(store.sections.active.find { |row| row.key == "f23c8673" }).not_to be_unread
    end
  end

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

  describe "ctrl-x deletes a session" do
    it "asks first and deletes once confirmed" do
      press(app, ctrl_x)
      expect(app).to paint("Delete comma3x not booting?")
      expect(client.removed).to be_empty

      press(app, "y")
      expect(wait_for { client.removed == %w[f23c8673] }).to be(true)
      expect(wait_for { store.entry("f23c8673").nil? }).to be(true)
      expect(screen(app).drop(1).join("\n")).not_to include("comma3x not booting")
    end

    it "keeps the session when the confirm is dismissed" do
      ["\e", "n", "q"].each do |dismiss|
        press(app, ctrl_x, dismiss)
        expect(app).not_to paint("Delete comma3x")
        expect(client.removed).to be_empty
      end
    end

    it "refuses on a terminal row instead of arming a confirm it can't honour" do
      press(app, "\t", ctrl_x)
      expect(app).not_to paint(/Delete .*\?/)
      expect(app).to paint("terminal").in_status_line
    end

    # Waiting for the stop to land is what makes "nothing was deleted" mean
    # anything: the action runs on a thread, so asserting it straight away
    # passes no matter which way the key was routed.
    it "still stops rather than deletes on X, sharing the one confirm" do
      press(app, "X")
      expect(app).to paint("Stop comma3x not booting?")

      press(app, "y")
      expect(wait_for { client.stopped == %w[f23c8673] }).to be(true)
      expect(client.removed).to be_empty
      expect(store.entry("f23c8673")).not_to be_nil
    end

    it "names the session by its alias when it has one" do
      store.set_alias("f23c8673", "comma boot")
      press(app, "X")
      expect(app).to paint("Stop comma boot?")
    end
  end

  describe "deleting a session" do
    it "says so while the worker runs, then confirms once it is gone" do
      client.hold
      press(app, ctrl_x, "y")
      expect(app).to paint("deleting comma3x not booting…").in_status_line

      client.release
      expect(wait_for { screen(app).first.include?("deleted comma3x not booting") }).to be(true)
    end
  end
end
