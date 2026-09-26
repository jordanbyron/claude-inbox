# frozen_string_literal: true

require_relative "../lib/claude_inbox/app"
require "stringio"
require "tmpdir"

CTRL_X = "\x18"
CTRL_S = "\x13"
CTRL_U = "\x15"

RSpec.describe ClaudeInbox::App do
  let(:terminal) { ScreenTerminal.new }

  let(:client) { RecordingClient.new }
  let(:store) { ClaudeInbox::Store.new(path: nil) }
  let(:pull_requests) { ClaudeInbox::PullRequests.new(cache_path: nil, resolved_path: nil, gh: nil) }
  let(:queue) { Queue.new }

  let(:app) do
    ClaudeInbox::App.new(
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

  def press(*keys) = keys.each { |k| app.step(k) }

  def screen
    app.step
    terminal.lines
  end

  def status_line = screen.first

  def footer = screen.last

  def selected_line = screen.find { |l| l.include?("▶") }

  # The selected row's key: the row itself carries a live age and spinner.
  def cursor
    app.step
    app.instance_variable_get(:@selected)&.key
  end

  def row_of(label) = screen.index { |l| l.include?(label) } + 1

  def click(col, row) = press("\e[<0;#{col};#{row}M")

  it "hands a paste to the new-session form whole, and types it into the filter" do
    press("/", "\e[200~thi\e[201~")
    expect(footer).to include("/thi")
    press("\e", "n", "\e[200~one\ntwo\e[201~")
    prompt = screen.select { |l| l.start_with?("  │") }.map { |l| l.delete("│").strip }
    expect(prompt.join("\n").strip).to eq("one\ntwo")
  end

  it "drops a paste that lands where nothing is typed, so its letters never act as keys" do
    press(CTRL_X, "\e[200~yes, every directory\e[201~")
    expect(screen.join("\n")).to include("Delete session f23c8673?")
    expect(client.removed).to be_empty
    press("\e", "N", "\e[200~query\e[201~")
    expect(screen.join("\n")).to include("Pair a phone")
    press("\e", "\e[200~q\e[201~")
    expect(screen.join("\n")).to include("comma3x not booting")
  end

  it "edits the filter line in the middle, and closes it on a backspace from empty" do
    press("/", "ac", "\e[D", "b")
    expect(footer).to include("/abc")
    press("\x01", "q")
    expect(footer).to include("/qabc")
    press("\x05", "\x7f", "\x7f", "\x7f", "\x7f")
    expect(footer.strip).to eq("/")
    press("\x7f")
    expect(footer).to include("j/k move")
  end

  describe "clicking a row" do
    it "selects it and attaches, same as landing on it and pressing Enter" do
      click(5, row_of("comma3x led flashing"))
      expect(client.attached).to eq(["823b882f"])
      expect(selected_line).to include("comma3x led flashing")
    end

    it "refuses on a terminal row instead of attaching, same as Enter" do
      click(5, row_of("claude-inbox-38"))
      expect(client.attached).to be_empty
      expect(status_line).to include("terminal")
    end

    it "expands a folded section when its toggle line is clicked" do
      store.settle("b03695b1")
      click(5, row_of("… 1 settled"))
      expect(screen.join("\n")).to include("app store release strategy")
    end

    it "ignores a click past the list column, such as one landing in the peek pane" do
      press("p")
      row = row_of("comma3x not booting")
      col = screen[row - 1].index("│") + 5
      click(col, row)
      expect(client.attached).to be_empty
    end
  end

  it "moves the selection on a wheel tick, the same way j/k would" do
    expect(selected_line).to include("comma3x not booting")
    press("\e[<65;1;1M")
    expect(selected_line).to include("claude-inbox-38")
    press("\e[<64;1;1M")
    expect(selected_line).to include("comma3x not booting")
  end

  describe "Tab and Shift-Tab" do
    it "walk a section headed by a terminal row like any other, and wrap" do
      store.settle("b03695b1")
      press("\t")
      expect(selected_line).to include("claude-inbox-38")
      press("\t")
      expect(selected_line).to include("… 1 settled")
      press("\t")
      expect(selected_line).to include("comma3x not booting")
      press("\e[Z")
      expect(selected_line).to include("… 1 settled")
    end
  end

  it "opens, closes and toggles the section under the cursor on zo, zc and za" do
    store.settle("b03695b1")
    press("\t", "\t")
    expect(screen.join("\n")).not_to include("app store release strategy")
    press("z", "o")
    expect(screen.join("\n")).to include("app store release strategy")
    press("\t", "\t")
    expect(selected_line).to include("app store release strategy")
    press("z", "c")
    expect(screen.join("\n")).not_to include("app store release strategy")
    press("\t", "\t", "z", "a")
    expect(screen.join("\n")).to include("app store release strategy")
  end

  describe "ctrl-x deletes a session" do
    it "asks first and deletes once confirmed" do
      press(CTRL_X)
      expect(screen.join("\n")).to include("Delete session f23c8673?")
      expect(client.removed).to be_empty

      press("y")
      expect(wait_for { client.removed == %w[f23c8673] }).to be(true)
      expect(wait_for { store.entry("f23c8673").nil? }).to be(true)
      expect(screen.join("\n")).not_to include("comma3x not booting")
    end

    it "keeps the session when the confirm is dismissed" do
      ["\e", "n", "q"].each do |dismiss|
        press(CTRL_X, dismiss)
        expect(screen.join("\n")).not_to include("Delete session")
        expect(client.removed).to be_empty
      end
    end

    it "refuses on a terminal row instead of arming a confirm it can't honour" do
      press("\t", CTRL_X)
      expect(screen.join("\n")).not_to include("Delete session")
      expect(status_line).to include("terminal")
    end

    # Waiting for the stop to land is what makes "nothing was deleted" mean
    # anything: the action runs on a thread, so asserting it straight away
    # passes no matter which way the key was routed.
    it "still stops rather than deletes on X, sharing the one confirm" do
      press("X")
      expect(screen.join("\n")).to include("Stop session f23c8673?")

      press("y")
      expect(wait_for { client.stopped == %w[f23c8673] }).to be(true)
      expect(client.removed).to be_empty
      expect(store.entry("f23c8673")).not_to be_nil
    end
  end

  describe "adopting a remote session" do
    let(:client) do
      Class.new(ClaudeInbox::FixtureClient) {
        def adopted = (@adopted ||= [])

        def attached = (@attached ||= [])

        def adopt(**opts)
          adopted << opts
          "adop7ed0"
        end

        def attach(id) = attached << id

        def release = nil
      }.new(fixture_path("agents.json"), origins: {57405 => :remote})
    end

    it "asks on Enter, then pulls the conversation in and attaches to it" do
      press("\t", "\r")
      expect(screen.join("\n")).to include("Pull this session into the daemon?")
      expect(client.adopted).to be_empty

      press("y")
      expect(wait_for {
        app.step
        client.attached == %w[adop7ed0]
      }).to be(true)
      expect(client.adopted).to eq([{session_id: "4a93393d-1c06-57da-9fb8-12f5b1535d95", cwd: "/Users/byron/code/claude-inbox", pid: 57405}])
    end

    it "leaves it alone when dismissed" do
      press("\t", "\r", "\e")
      expect(screen.join("\n")).not_to include("Pull this session")
      expect(client.adopted).to be_empty
    end
  end

  describe "starting a session" do
    it "says so while the worker runs, then names the session and lands on its row" do
      client.hold
      # The form defaults to the selected fixture row's cwd, a path from the
      # machine the fixture was captured on, so point it somewhere real.
      press("n", "h", "i", "\e[B", "\e[B", CTRL_U, *Dir.pwd.chars, CTRL_S)
      expect(status_line).to include("starting session…")

      client.release
      expect(wait_for { status_line.include?("started deadbeef") }).to be(true)
      store.update(store.sessions + [session(id: "deadbeef", name: "fresh one")])
      expect(selected_line).to include("fresh one")
    end

    # A directory `claude` has never run in before is exactly where `claude
    # --bg` is most likely to fail (nothing there to answer its first-run
    # trust prompt), so the form has to hand the composed prompt back rather
    # than dropping it once the spawn is known to have failed.
    it "reopens the form with the prompt and the error, instead of losing it, when the spawn fails" do
      client.fail_spawn("claude --bg failed: not a trusted directory")
      press("n", *"fix the thing".chars, "\e[B", "\e[B", CTRL_U, *Dir.pwd.chars, CTRL_S)
      expect(wait_for { screen.join("\n").include?("not a trusted directory") }).to be(true)
      lines = screen
      expect(lines.join("\n")).to include("fix the thing")
      expect(lines.join("\n")).to include("New session")
      press(CTRL_S)
      expect(status_line).to include("starting session…")
    end
  end

  describe "a session started from another device" do
    it "says so, without moving the cursor or closing the form someone is typing in" do
      press("j")
      before = cursor
      expect(before).not_to be_nil
      press("n", *"half a thought".chars)
      queue << [:notice, "remote: starting session…"]
      expect(status_line).to include("remote: starting session…")

      store.update(store.sessions + [session(id: "31472308", name: "from the phone")])
      queue << [:remote_started, "31472308", "192.168.1.30"]
      lines = screen
      expect(lines.first).to include("started 31472308 from 192.168.1.30")
      expect(lines.join("\n")).to include("New session")
      expect(lines.join("\n")).to include("half a thought")
      expect(client.attached).to be_empty

      press("\e", "y")
      expect(cursor).to eq(before)
      expect(screen.join("\n")).to include("from the phone")
    end
  end

  describe "N with the listener on" do
    let(:tmp) { Dir.mktmpdir }
    let(:gate) { Queue.new }
    let(:pairing) do
      ClaudeInbox::Remote::Pairing.new(path: File.join(tmp, "listen.json"), local_name: -> { "m" }, addresses: -> { [] }).tap do |p|
        lookups = gate
        p.define_singleton_method(:urls) do |**kw|
          lookups.pop
          super(**kw)
        end
      end
    end
    let(:app) do
      ClaudeInbox::App.new(
        client: client, store: store, pull_requests: pull_requests,
        rate_limits: ClaudeInbox::RateLimits.new(path: fixture_path("rate_limits.json")),
        terminal: terminal, input: StringIO.new, color: false, queue: queue,
        listen: {port: 0, pairing: pairing, lock_path: File.join(tmp, "listen.lock"), images_dir: File.join(tmp, "images")}
      )
    end
    let(:listener) { app.instance_variable_get(:@listener) }

    before { listener.start }

    after do
      gate.close
      listener.stop
      FileUtils.remove_entry(tmp)
    end

    it "shows the port in the header, and the URL once the lookup lands" do
      expect(status_line).to include("◉ :#{listener.port}")
      press("N")
      expect(screen.join("\n")).to include("listening on 127.0.0.1:#{listener.port}")
      expect(screen.join("\n")).to include("looking up this Mac's addresses…")
      press("c")
      expect(status_line).to include("still looking up this Mac's addresses")
      gate << true
      expect(wait_for { screen.join("\n").include?("http://127.0.0.1:#{listener.port}/#") }).to be(true)
    end

    it "issues a new token on r then y, and says phones must pair again" do
      old = pairing.token
      press("N", "r")
      expect(screen.join("\n")).to include("rotate? y/n")
      gate << true << true
      press("y")
      expect(wait_for { status_line.include?("new token: phones pair again with N") }).to be(true)
      expect(JSON.parse(File.read(File.join(tmp, "listen.json")))["token"]).not_to eq(old)
    end
  end

  describe "N" do
    it "opens the pairing dialog, which says how to turn the listener on while it is off" do
      press("N")
      expect(screen.join("\n")).to include("off: start with --listen or --listen-lan")
      expect(screen.join("\n")).to include("esc close")
      press("c", "r", "y")
      expect(screen.join("\n")).not_to include("rotate?")
      expect(screen.join("\n")).to include("Pair a phone")
      press("\e")
      expect(screen.join("\n")).not_to include("Pair a phone")
    end
  end

  describe "opening a new session" do
    it "strips a trailing worktree path so the new session lands in the repo it was cut from" do
      store.update(store.sessions + [
        session(id: "aaaa1111", name: "cut from a worktree", cwd: "/Users/byron/code/claude-inbox/.claude/worktrees/foo"),
        session(id: "bbbb2222", name: "deep in a worktree", cwd: "/Users/byron/code/claude-inbox/.claude/worktrees/foo/lib")
      ])
      {"cut from" => "/Users/byron/code/claude-inbox", "deep in" => "/Users/byron/code/claude-inbox", "not booting" => "/Users/byron/code/comma3"}.each do |name, dir|
        press("/", *name.chars, "\r", "n")
        expect(screen.find { |l| l.include?("Directory") }.split("Directory").last.strip).to eq(dir)
        press("\e", "\e")
      end
    end
  end

  describe "deleting a session" do
    it "says so while the worker runs, then confirms once it is gone" do
      client.hold
      press(CTRL_X, "y")
      expect(status_line).to include("deleting f23c8673…")

      client.release
      expect(wait_for { status_line.include?("deleted f23c8673") }).to be(true)
    end
  end

  describe "alias and pull request editors" do
    it "seed their buffer from the store, so reopening shows what was saved" do
      store.set_alias("f23c8673", "auth spike")
      store.set_pr("f23c8673", "https://github.com/o/r/pull/7")

      press("a")
      expect(screen.join("\n")).to include("> auth spike")
      press("\e", "P")
      expect(screen.join("\n")).to include("> https://github.com/o/r/pull/7")
    end
  end
end
