# frozen_string_literal: true

require "stringio"
require "tmpdir"

RSpec.describe ClaudeInbox::App do
  let(:ctrl_s) { "\x13" }
  let(:ctrl_u) { "\x15" }

  let(:terminal) { ScreenTerminal.new }

  let(:client) { RecordingClient.new }
  let(:store) { ClaudeInbox::Store.new(path: nil) }
  let(:pull_requests) { ClaudeInbox::PullRequests.new(cache_path: nil, resolved_path: nil, gh: nil) }
  let(:queue) { Queue.new }
  let(:trusted) { [] }

  let(:app) do
    described_class.new(
      client: client, store: store, pull_requests: pull_requests,
      rate_limits: ClaudeInbox::RateLimits.new(path: fixture_path("rate_limits.json")),
      terminal: terminal, input: StringIO.new, color: false, queue: queue, trust: -> { trusted }
    )
  end

  before do
    store.update(ClaudeInbox::Sessions.load(client: client, pull_requests: pull_requests, overrides: {}))
    app.step
  end

  after { client.release }

  describe "starting a session" do
    it "says so while the worker runs, then names the session and lands on its row" do
      client.hold
      # The form defaults to the selected fixture row's cwd, a path from the
      # machine the fixture was captured on, so point it somewhere real.
      press(app, "n", "h", "i", "\e[B", "\e[B", ctrl_u, *Dir.pwd.chars, ctrl_s)
      expect(app).to paint("starting session…").in_status_line

      client.release
      expect(wait_for { screen(app).first.include?("started deadbeef") }).to be(true)
      store.update(store.sessions + [session(id: "deadbeef", name: "fresh one")])
      expect(app).to paint("fresh one").on_selected_row
    end

    # A directory `claude` has never run in before is exactly where `claude
    # --bg` is most likely to fail (nothing there to answer its first-run
    # trust prompt), so the form has to hand the composed prompt back rather
    # than dropping it once the spawn is known to have failed.
    it "offers the trusted directories as the Directory field is typed in" do
      Dir.mktmpdir("picked") do |dir|
        trusted.replace([dir])
        press(app, "n", "\e[B", "\e[B", ctrl_u, *"picked".chars)
        expect(screen(app).join("\n")).to include(File.basename(dir))
        press(app, "\r")
        expect(screen(app).find { |l| l.include?("Directory") }).to include("/#{File.basename(dir)}")
      end
    end

    it "reopens the form with the prompt and the error, instead of losing it, when the spawn fails" do
      client.fail_spawn("claude --bg failed: not a trusted directory")
      press(app, "n", *"fix the thing".chars, "\e[B", "\e[B", ctrl_u, *Dir.pwd.chars, ctrl_s)
      expect(wait_for { screen(app).join("\n").include?("not a trusted directory") }).to be(true)
      lines = screen(app)
      expect(lines.join("\n")).to include("fix the thing")
      expect(lines.join("\n")).to include("New session")
      press(app, ctrl_s)
      expect(app).to paint("starting session…").in_status_line
    end
  end

  describe "a session started from another device" do
    it "says so, without moving the cursor or closing the form someone is typing in" do
      press(app, "j")
      # Compare the selected row's key: the row itself carries a live age and spinner.
      app.step
      before = app.instance_variable_get(:@selected)&.key
      expect(before).not_to be_nil
      press(app, "n", *"half a thought".chars)
      queue << [:notice, "remote: starting session…"]
      expect(app).to paint("remote: starting session…").in_status_line

      store.update(store.sessions + [session(id: "31472308", name: "from the phone")])
      queue << [:remote_started, "31472308", "192.168.1.30"]
      lines = screen(app)
      expect(lines.first).to include("started 31472308 from 192.168.1.30")
      expect(lines.join("\n")).to include("New session")
      expect(lines.join("\n")).to include("half a thought")
      expect(client.attached).to be_empty

      press(app, "\e", "y")
      app.step
      expect(app.instance_variable_get(:@selected)&.key).to eq(before)
      expect(app).to paint("from the phone")
    end
  end

  describe "opening a new session" do
    it "strips a trailing worktree path so the new session lands in the repo it was cut from" do
      store.update(store.sessions + [
        session(
          id: "aaaa1111",
          name: "cut from a worktree",
          cwd: "/Users/byron/code/claude-inbox/.claude/worktrees/foo"
        ),
        session(
          id: "bbbb2222",
          name: "deep in a worktree",
          cwd: "/Users/byron/code/claude-inbox/.claude/worktrees/foo/lib"
        )
      ])
      {
        "cut from" => "/Users/byron/code/claude-inbox",
        "deep in" => "/Users/byron/code/claude-inbox",
        "not booting" => "/Users/byron/code/comma3"
      }.each do |name, dir|
        press(app, "/", *name.chars, "\r", "n")
        expect(screen(app).find { |l| l.include?("Directory") }.split("Directory").last.strip).to eq(dir)
        press(app, "\e", "\e")
      end
    end
  end
end
