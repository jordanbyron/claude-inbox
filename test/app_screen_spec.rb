# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/claude_inbox/app"
require "stringio"

CTRL_X = "\x18"
CTRL_S = "\x13"

describe ClaudeInbox::App do
  let(:terminal) { ScreenTerminal.new }

  let(:client) do
    Class.new(ClaudeInbox::FixtureClient) {
      def removed = (@removed ||= [])

      def stopped = (@stopped ||= [])

      def attached = (@attached ||= [])

      def hold = @gate = Queue.new

      def release = @gate&.push(true)

      def rm(id)
        @gate&.pop
        removed << id
        true
      end

      def stop(id)
        stopped << id
        true
      end

      def attach(id) = attached << id

      def spawn(**)
        @gate&.pop
        "deadbeef"
      end
    }.new(fixture_path("agents.json"))
  end

  let(:store) { ClaudeInbox::Store.new(path: nil) }
  let(:pull_requests) { ClaudeInbox::PullRequests.new(cache_path: nil, resolved_path: nil, gh: nil) }

  let(:app) do
    ClaudeInbox::App.new(
      client: client, store: store, pull_requests: pull_requests, jobs_dir: fixture_path("jobs"),
      rate_limits: ClaudeInbox::RateLimits.new(path: fixture_path("rate_limits.json")),
      terminal: terminal, input: StringIO.new, color: false
    )
  end

  before do
    store.update(ClaudeInbox::Sessions.load(client: client, jobs_dir: fixture_path("jobs"), pull_requests: pull_requests, overrides: {}))
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

  def row_of(label) = screen.index { |l| l.include?(label) } + 1

  def click(col, row) = press("\e[<0;#{col};#{row}M")

  it "hands a paste to the new-session form whole, and types it into the filter" do
    press("/", "\e[200~thi\e[201~")
    _(footer).must_include "/thi"
    press("\e", "n", "\e[200~one\ntwo\e[201~")
    prompt = screen.select { |l| l.start_with?("  │") }.map { |l| l.delete("│").strip }
    _(prompt.join("\n").strip).must_equal "one\ntwo"
  end

  it "edits the filter line in the middle, and closes it on a backspace from empty" do
    press("/", "ac", "\e[D", "b")
    _(footer).must_include "/abc"
    press("\x01", "q")
    _(footer).must_include "/qabc"
    press("\x05", "\x7f", "\x7f", "\x7f", "\x7f")
    _(footer.strip).must_equal "/"
    press("\x7f")
    _(footer).must_include "j/k move"
  end

  describe "clicking a row" do
    it "selects it and attaches, same as landing on it and pressing Enter" do
      click(5, row_of("comma3x led flashing"))
      _(client.attached).must_equal ["823b882f"]
      _(selected_line).must_include "comma3x led flashing"
    end

    it "refuses on a terminal row instead of attaching, same as Enter" do
      click(5, row_of("claude-inbox-38"))
      _(client.attached).must_be_empty
      _(status_line).must_include "terminal"
    end

    it "expands a folded section when its toggle line is clicked" do
      store.settle("b03695b1")
      click(5, row_of("… 1 settled"))
      _(screen.join("\n")).must_include "app store release strategy"
    end

    it "ignores a click past the list column, such as one landing in the peek pane" do
      press("p")
      row = row_of("comma3x not booting")
      col = screen[row - 1].index("│") + 5
      click(col, row)
      _(client.attached).must_be_empty
    end
  end

  it "moves the selection on a wheel tick, the same way j/k would" do
    _(selected_line).must_include "comma3x not booting"
    press("\e[<65;1;1M")
    _(selected_line).must_include "claude-inbox-38"
    press("\e[<64;1;1M")
    _(selected_line).must_include "comma3x not booting"
  end

  describe "Tab and Shift-Tab" do
    it "walk a section headed by a terminal row like any other, and wrap" do
      store.settle("b03695b1")
      press("\t")
      _(selected_line).must_include "claude-inbox-38"
      press("\t")
      _(selected_line).must_include "… 1 settled"
      press("\t")
      _(selected_line).must_include "comma3x not booting"
      press("\e[Z")
      _(selected_line).must_include "… 1 settled"
    end
  end

  describe "ctrl-x deletes a session" do
    it "asks first and deletes once confirmed" do
      press(CTRL_X)
      _(screen.join("\n")).must_include "Delete session f23c8673?"
      _(client.removed).must_be_empty

      press("y")
      _(wait_for { client.removed == %w[f23c8673] }).must_equal true
      _(wait_for { store.entry("f23c8673").nil? }).must_equal true
      _(screen.join("\n")).wont_include "comma3x not booting"
    end

    it "keeps the session when the confirm is dismissed" do
      ["\e", "n", "q"].each do |dismiss|
        press(CTRL_X, dismiss)
        _(screen.join("\n")).wont_include "Delete session"
        _(client.removed).must_be_empty
      end
    end

    it "refuses on a terminal row instead of arming a confirm it can't honour" do
      press("\t", CTRL_X)
      _(screen.join("\n")).wont_include "Delete session"
      _(status_line).must_include "terminal"
    end

    # Waiting for the stop to land is what makes "nothing was deleted" mean
    # anything: the action runs on a thread, so asserting it straight away
    # passes no matter which way the key was routed.
    it "still stops rather than deletes on X, sharing the one confirm" do
      press("X")
      _(screen.join("\n")).must_include "Stop session f23c8673?"

      press("y")
      _(wait_for { client.stopped == %w[f23c8673] }).must_equal true
      _(client.removed).must_be_empty
      _(store.entry("f23c8673")).wont_be_nil
    end
  end

  describe "starting a session" do
    it "says so while the worker runs, then names the session and lands on its row" do
      client.hold
      press("n", "h", "i", CTRL_S)
      _(status_line).must_include "starting session…"

      client.release
      _(wait_for { status_line.include?("started deadbeef") }).must_equal true
      store.update(store.sessions + [session(id: "deadbeef", name: "fresh one")])
      _(selected_line).must_include "fresh one"
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
        _(screen.find { |l| l.include?("Directory") }.split("Directory").last.strip).must_equal dir
        press("\e", "\e")
      end
    end
  end

  describe "deleting a session" do
    it "says so while the worker runs, then confirms once it is gone" do
      client.hold
      press(CTRL_X, "y")
      _(status_line).must_include "deleting f23c8673…"

      client.release
      _(wait_for { status_line.include?("deleted f23c8673") }).must_equal true
    end
  end

  describe "alias and pull request editors" do
    it "seed their buffer from the store, so reopening shows what was saved" do
      store.set_alias("f23c8673", "auth spike")
      store.set_pr("f23c8673", "https://github.com/o/r/pull/7")

      press("a")
      _(screen.join("\n")).must_include "> auth spike"
      press("\e", "P")
      _(screen.join("\n")).must_include "> https://github.com/o/r/pull/7"
    end
  end
end
