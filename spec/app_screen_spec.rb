# frozen_string_literal: true

require "stringio"
require "tmpdir"

RSpec.describe ClaudeInbox::App do
  let(:ctrl_x) { "\x18" }
  let(:ctrl_s) { "\x13" }
  let(:ctrl_u) { "\x15" }

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

  it "hands a paste to the new-session form whole, and types it into the filter" do
    ["/", "\e[200~thi\e[201~"].each { |k| app.step(k) }
    expect(app).to paint("/thi").in_footer
    ["\e", "n", "\e[200~one\ntwo\e[201~"].each { |k| app.step(k) }
    expect(app).to paint(/┌─+┐\s+│ one +│\s+│ two +│\s+│ +│/)
  end

  it "drops a paste that lands where nothing is typed, so its letters never act as keys" do
    [ctrl_x, "\e[200~yes, every directory\e[201~"].each { |k| app.step(k) }
    expect(app).to paint("Delete session f23c8673?")
    expect(client.removed).to be_empty
    ["\e", "N", "\e[200~query\e[201~"].each { |k| app.step(k) }
    expect(app).to paint("Pair a phone")
    ["\e", "\e[200~q\e[201~"].each { |k| app.step(k) }
    expect(app).to paint("comma3x not booting")
  end

  it "edits the filter line in the middle, and closes it on a backspace from empty" do
    ["/", "ac", "\e[D", "b"].each { |k| app.step(k) }
    expect(app).to paint("/abc").in_footer
    ["\x01", "q"].each { |k| app.step(k) }
    expect(app).to paint("/qabc").in_footer
    ["\x05", "\x7f", "\x7f", "\x7f", "\x7f"].each { |k| app.step(k) }
    expect(app).to paint(/\A *\/ *\z/).in_footer
    app.step("\x7f")
    expect(app).to paint("j/k move").in_footer
  end

  describe "clicking a row" do
    subject(:click) { app.step("\e[<0;#{col};#{row}M") }

    let(:frame) {
      app.step
      terminal.lines
    }
    let(:row) { frame.index { |l| l.include?(label) } + 1 }
    let(:col) { 5 }

    context "on a session" do
      let(:label) { "comma3x led flashing" }

      it "selects it and attaches, same as landing on it and pressing Enter" do
        click
        expect(client.attached).to eq(["823b882f"])
        expect(app).to paint("comma3x led flashing").on_selected_row
      end
    end

    context "on a terminal row" do
      let(:label) { "claude-inbox-38" }

      it "refuses on a terminal row instead of attaching, same as Enter" do
        click
        expect(client.attached).to be_empty
        expect(app).to paint("terminal").in_status_line
      end
    end

    context "on a folded section's toggle line" do
      let(:label) { "… 1 settled" }

      before { store.settle("b03695b1") }

      it "expands a folded section when its toggle line is clicked" do
        click
        expect(app).to paint("app store release strategy")
      end
    end

    context "past the list column, with the peek pane open" do
      let(:label) { "comma3x not booting" }
      let(:col) { frame[row - 1].index("│") + 5 }

      before { app.step("p") }

      it "ignores a click past the list column, such as one landing in the peek pane" do
        click
        expect(client.attached).to be_empty
      end
    end
  end

  it "moves the selection on a wheel tick, the same way j/k would" do
    expect(app).to paint("comma3x not booting").on_selected_row
    app.step("\e[<65;1;1M")
    expect(app).to paint("claude-inbox-38").on_selected_row
    app.step("\e[<64;1;1M")
    expect(app).to paint("comma3x not booting").on_selected_row
  end

  describe "Tab and Shift-Tab" do
    it "walk a section headed by a terminal row like any other, and wrap" do
      store.settle("b03695b1")
      app.step("\t")
      expect(app).to paint("claude-inbox-38").on_selected_row
      app.step("\t")
      expect(app).to paint("… 1 settled").on_selected_row
      app.step("\t")
      expect(app).to paint("comma3x not booting").on_selected_row
      app.step("\e[Z")
      expect(app).to paint("… 1 settled").on_selected_row
    end
  end

  it "opens, closes and toggles the section under the cursor on zo, zc and za" do
    store.settle("b03695b1")
    ["\t", "\t"].each { |k| app.step(k) }
    expect(app).not_to paint("app store release strategy")
    ["z", "o"].each { |k| app.step(k) }
    expect(app).to paint("app store release strategy")
    ["\t", "\t"].each { |k| app.step(k) }
    expect(app).to paint("app store release strategy").on_selected_row
    ["z", "c"].each { |k| app.step(k) }
    expect(app).not_to paint("app store release strategy")
    ["\t", "\t", "z", "a"].each { |k| app.step(k) }
    expect(app).to paint("app store release strategy")
  end

  describe "ctrl-x deletes a session" do
    it "asks first and deletes once confirmed" do
      app.step(ctrl_x)
      expect(app).to paint("Delete session f23c8673?")
      expect(client.removed).to be_empty

      app.step("y")
      expect(wait_for { client.removed == %w[f23c8673] }).to be(true)
      expect(wait_for { store.entry("f23c8673").nil? }).to be(true)
      expect(app).not_to paint("comma3x not booting")
    end

    it "keeps the session when the confirm is dismissed" do
      ["\e", "n", "q"].each do |dismiss|
        [ctrl_x, dismiss].each { |k| app.step(k) }
        expect(app).not_to paint("Delete session")
        expect(client.removed).to be_empty
      end
    end

    it "refuses on a terminal row instead of arming a confirm it can't honour" do
      ["\t", ctrl_x].each { |k| app.step(k) }
      expect(app).not_to paint("Delete session")
      expect(app).to paint("terminal").in_status_line
    end

    # Waiting for the stop to land is what makes "nothing was deleted" mean
    # anything: the action runs on a thread, so asserting it straight away
    # passes no matter which way the key was routed.
    it "still stops rather than deletes on X, sharing the one confirm" do
      app.step("X")
      expect(app).to paint("Stop session f23c8673?")

      app.step("y")
      expect(wait_for { client.stopped == %w[f23c8673] }).to be(true)
      expect(client.removed).to be_empty
      expect(store.entry("f23c8673")).not_to be_nil
    end
  end

  describe "adopting a remote session" do
    let(:client) { RecordingClient.new(origins: {57405 => :remote}) }

    before do
      allow(client).to receive(:adopt).and_call_original
      ["\t", "\r"].each { |k| app.step(k) }
    end

    it "asks on Enter, then pulls the conversation in and attaches to it" do
      expect(app).to paint("Pull this session into the daemon?")
      expect(client).not_to have_received(:adopt)

      app.step("y")
      expect(wait_for {
        app.step
        client.attached == %w[adop7ed0]
      }).to be(true)
      expect(client).to have_received(:adopt).once.with(session_id: "4a93393d-1c06-57da-9fb8-12f5b1535d95", cwd: "/Users/byron/code/claude-inbox", pid: 57405)
    end

    it "leaves it alone when dismissed" do
      app.step("\e")
      expect(app).not_to paint("Pull this session")
      expect(client).not_to have_received(:adopt)
    end
  end

  describe "starting a session" do
    it "says so while the worker runs, then names the session and lands on its row" do
      client.hold
      # The form defaults to the selected fixture row's cwd, a path from the
      # machine the fixture was captured on, so point it somewhere real.
      ["n", "h", "i", "\e[B", "\e[B", ctrl_u, *Dir.pwd.chars, ctrl_s].each { |k| app.step(k) }
      expect(app).to paint("starting session…").in_status_line

      client.release
      expect(app).to eventually paint("started deadbeef").in_status_line
      store.update(store.sessions + [session(id: "deadbeef", name: "fresh one")])
      expect(app).to paint("fresh one").on_selected_row
    end

    # A directory `claude` has never run in before is exactly where `claude
    # --bg` is most likely to fail (nothing there to answer its first-run
    # trust prompt), so the form has to hand the composed prompt back rather
    # than dropping it once the spawn is known to have failed.
    it "reopens the form with the prompt and the error, instead of losing it, when the spawn fails" do
      client.fail_spawn("claude --bg failed: not a trusted directory")
      ["n", *"fix the thing".chars, "\e[B", "\e[B", ctrl_u, *Dir.pwd.chars, ctrl_s].each { |k| app.step(k) }
      expect(app).to eventually paint("not a trusted directory")
      expect(app).to paint("fix the thing")
      expect(app).to paint("New session")
      app.step(ctrl_s)
      expect(app).to paint("starting session…").in_status_line
    end
  end

  describe "a session started from another device" do
    # The selected row's key rather than its line: the row carries a live
    # age and spinner.
    it "says so, without moving the cursor or closing the form someone is typing in" do
      app.step("j")
      app.step
      before = app.instance_variable_get(:@selected)&.key
      expect(before).not_to be_nil
      ["n", *"half a thought".chars].each { |k| app.step(k) }
      queue << [:notice, "remote: starting session…"]
      expect(app).to paint("remote: starting session…").in_status_line

      store.update(store.sessions + [session(id: "31472308", name: "from the phone")])
      queue << [:remote_started, "31472308", "192.168.1.30"]
      expect(app).to paint("started 31472308 from 192.168.1.30").in_status_line
      expect(app).to paint("New session")
      expect(app).to paint("half a thought")
      expect(client.attached).to be_empty

      ["\e", "y"].each { |k| app.step(k) }
      app.step
      expect(app.instance_variable_get(:@selected)&.key).to eq(before)
      expect(app).to paint("from the phone")
    end
  end

  describe "N with the listener on" do
    let(:tmp) { Dir.mktmpdir }
    let(:gate) { Queue.new }
    let(:pairing) do
      ClaudeInbox::Remote::Pairing.new(path: File.join(tmp, "listen.json"), local_name: -> { "m" }, addresses: -> { [] }).tap do |p|
        allow(p).to receive(:urls).and_wrap_original do |urls, **kw|
          gate.pop
          urls.call(**kw)
        end
      end
    end
    let(:app) do
      described_class.new(
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
      expect(app).to paint("◉ :#{listener.port}").in_status_line
      app.step("N")
      expect(app).to paint("listening on 127.0.0.1:#{listener.port}")
      expect(app).to paint("looking up this Mac's addresses…")
      app.step("c")
      expect(app).to paint("still looking up this Mac's addresses").in_status_line
      gate << true
      expect(app).to eventually paint("http://127.0.0.1:#{listener.port}/#")
    end

    it "issues a new token on r then y, and says phones must pair again" do
      old = pairing.token
      ["N", "r"].each { |k| app.step(k) }
      expect(app).to paint("rotate? y/n")
      gate << true << true
      app.step("y")
      expect(app).to eventually paint("new token: phones pair again with N").in_status_line
      expect(JSON.parse(File.read(File.join(tmp, "listen.json")))["token"]).not_to eq(old)
    end
  end

  describe "N" do
    it "opens the pairing dialog, which says how to turn the listener on while it is off" do
      app.step("N")
      expect(app).to paint("off: start with --listen or --listen-lan")
      expect(app).to paint("esc close")
      ["c", "r", "y"].each { |k| app.step(k) }
      expect(app).not_to paint("rotate?")
      expect(app).to paint("Pair a phone")
      app.step("\e")
      expect(app).not_to paint("Pair a phone")
    end
  end

  describe "opening a new session" do
    before do
      store.update(store.sessions + [
        session(id: "aaaa1111", name: "cut from a worktree", cwd: "/Users/byron/code/claude-inbox/.claude/worktrees/foo"),
        session(id: "bbbb2222", name: "deep in a worktree", cwd: "/Users/byron/code/claude-inbox/.claude/worktrees/foo/lib")
      ])
    end

    it "strips a trailing worktree path so the new session lands in the repo it was cut from" do
      {"cut from" => "/Users/byron/code/claude-inbox", "deep in" => "/Users/byron/code/claude-inbox", "not booting" => "/Users/byron/code/comma3"}.each do |name, dir|
        ["/", *name.chars, "\r", "n"].each { |k| app.step(k) }
        expect(app).to paint(/Directory +#{Regexp.escape(dir)} *$/)
        ["\e", "\e"].each { |k| app.step(k) }
      end
    end
  end

  describe "deleting a session" do
    it "says so while the worker runs, then confirms once it is gone" do
      client.hold
      [ctrl_x, "y"].each { |k| app.step(k) }
      expect(app).to paint("deleting f23c8673…").in_status_line

      client.release
      expect(app).to eventually paint("deleted f23c8673").in_status_line
    end
  end

  describe "alias and pull request editors" do
    before do
      store.set_alias("f23c8673", "auth spike")
      store.set_pr("f23c8673", "https://github.com/o/r/pull/7")
    end

    it "seed their buffer from the store, so reopening shows what was saved" do
      app.step("a")
      expect(app).to paint("> auth spike")
      ["\e", "P"].each { |k| app.step(k) }
      expect(app).to paint("> https://github.com/o/r/pull/7")
    end
  end
end
