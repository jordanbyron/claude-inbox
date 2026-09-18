# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/claude_inbox/app"
require "stringio"

CTRL_X = "\x18"

describe ClaudeInbox::App do
  let(:out) { StringIO.new }

  let(:client) do
    Class.new(ClaudeInbox::FixtureClient) {
      def removed = (@removed ||= [])

      def stopped = (@stopped ||= [])

      def rm(id)
        removed << id
        true
      end

      def stop(id)
        stopped << id
        true
      end
    }.new(fixture_path("agents.json"))
  end

  let(:store) { ClaudeInbox::Store.new(path: nil) }

  let(:app) do
    ClaudeInbox::App.new(
      client: client,
      store: store,
      pull_requests: ClaudeInbox::PullRequests.new(jobs_dir: fixture_path("jobs"), cache_path: nil, resolved_path: nil, gh: nil),
      jobs_dir: fixture_path("jobs"),
      out: out, input: StringIO.new, color: false
    )
  end

  it "fills in each session's color from its job file on every poll" do
    loaded_app(nil)
    by_id = store.sessions.to_h { |s| [s.id, s.color] }
    _(by_id["b0b18338"]).must_equal "orange"
    _(by_id["b03695b1"]).must_be_nil
  end

  def loaded_app(selected)
    app.tap do |a|
      a.send(:poll_once)
      a.send(:drain_queue)
      a.instance_variable_set(:@selected, selected)
    end
  end

  def wait_for(timeout: 2)
    deadline = Time.now + timeout
    sleep 0.01 while !yield && Time.now < deadline
    yield
  end

  # StringIO#string hands back the live buffer, so copy before clearing it.
  def taken = out.string.dup.tap {
    out.truncate(0)
    out.rewind
  }

  # A row's screen line, found the same way the paint did it: by scanning
  # the row->item map render just built, rather than assuming a layout.
  def row_for(a, key)
    idx = a.instance_variable_get(:@row_items).index { |item| item&.key == key }
    idx + 1
  end

  it "takes the wheel for the duration of the alt screen and hands it back" do
    app.send(:enter_screen)
    entered = taken
    _(entered).must_include ClaudeInbox::App::ALT_ON
    _(entered).must_include ClaudeInbox::App::WHEEL_KEYS_ON

    app.send(:restore_screen)
    left = taken
    _(left).must_include ClaudeInbox::App::WHEEL_KEYS_OFF
    # The mode belongs to the alt screen, so it has to go first.
    _(left.index(ClaudeInbox::App::WHEEL_KEYS_OFF)).must_be :<, left.index(ClaudeInbox::App::ALT_OFF)
  end

  it "takes over the mouse for the duration of the alt screen and hands it back" do
    app.send(:enter_screen)
    entered = taken
    _(entered).must_include ClaudeInbox::App::MOUSE_ON

    app.send(:restore_screen)
    left = taken
    _(left).must_include ClaudeInbox::App::MOUSE_OFF
    _(left.index(ClaudeInbox::App::MOUSE_OFF)).must_be :<, left.index(ClaudeInbox::App::ALT_OFF)
  end

  describe "clicking a row" do
    def with_peek(a)
      a.instance_variable_set(:@peek, ClaudeInbox::Peek.new(client, Queue.new))
      a
    end

    it "selects it and attaches, same as landing on it and pressing Enter" do
      a = with_peek(loaded_app(nil))
      a.send(:render)
      attached = []
      a.define_singleton_method(:attach) { |id| attached << id }
      row = row_for(a, "f23c8673")

      a.send(:handle_input, "\e[<0;5;#{row}M")

      _(a.instance_variable_get(:@selected)).must_equal "f23c8673"
      _(attached).must_equal ["f23c8673"]
    end

    it "refuses on a terminal row instead of attaching, same as Enter" do
      a = with_peek(loaded_app(nil))
      a.send(:render)
      row = row_for(a, "4a93393d-1c06-57da-9fb8-12f5b1535d95")

      a.send(:handle_input, "\e[<0;5;#{row}M")

      _(a.instance_variable_get(:@notice)[0]).must_include "terminal"
    end

    it "expands a folded section when its toggle line is clicked" do
      a = with_peek(loaded_app(nil))
      a.send(:render)
      row = row_for(a, :settled)

      a.send(:handle_input, "\e[<0;5;#{row}M")

      _(a.instance_variable_get(:@expanded)[:settled]).must_equal true
    end

    it "ignores a click past the list column, such as one landing in the peek pane" do
      a = with_peek(loaded_app("f23c8673"))
      a.instance_variable_set(:@peek_on, true)
      a.send(:render)
      attached = []
      a.define_singleton_method(:attach) { |id| attached << id }
      row = row_for(a, "f23c8673")
      col = a.instance_variable_get(:@list_width) + 5

      a.send(:handle_input, "\e[<0;#{col};#{row}M")

      _(attached).must_be_empty
    end
  end

  it "moves the selection on a wheel tick, the same way j/k would" do
    a = loaded_app("f23c8673")
    a.send(:render)
    keys = a.send(:selectable_keys, a.send(:filtered, store.sections))
    idx = keys.index("f23c8673")

    a.send(:handle_input, "\e[<65;1;1M")

    _(a.instance_variable_get(:@selected)).must_equal keys[idx + 1]
  end

  describe "ctrl-x deletes a session" do
    it "asks first and deletes once confirmed" do
      a = loaded_app("f23c8673")

      a.send(:handle_key, CTRL_X)
      _(a.send(:modal_lines, 60).join("\n")).must_include "Delete session f23c8673?"
      _(client.removed).must_be_empty

      a.send(:handle_key, "y")
      _(wait_for { client.removed == %w[f23c8673] }).must_equal true
      _(wait_for { store.entry("f23c8673").nil? }).must_equal true
    end

    it "keeps the session when the confirm is dismissed" do
      ["\e", "n", "q"].each do |dismiss|
        a = loaded_app("f23c8673")
        a.send(:handle_key, CTRL_X)
        a.send(:handle_key, dismiss)

        _(a.send(:modal_lines, 60)).must_be_nil
        _(client.removed).must_be_empty
      end
    end

    it "refuses on a terminal row instead of arming a confirm it can't honour" do
      a = loaded_app("4a93393d-1c06-57da-9fb8-12f5b1535d95")
      a.send(:handle_key, CTRL_X)

      _(a.send(:modal_lines, 60)).must_be_nil
      _(a.instance_variable_get(:@notice)[0]).must_include "terminal"
    end

    # Waiting for the stop to land is what makes "nothing was deleted" mean
    # anything: the action runs on a thread, so asserting it straight away
    # passes no matter which way the key was routed.
    it "still stops rather than deletes on X, sharing the one confirm" do
      a = loaded_app("f23c8673")
      a.send(:handle_key, "X")
      _(a.send(:modal_lines, 60).join("\n")).must_include "Stop session f23c8673?"

      a.send(:handle_key, "y")
      _(wait_for { client.stopped == %w[f23c8673] }).must_equal true
      _(client.removed).must_be_empty
      _(store.entry("f23c8673")).wont_be_nil
    end
  end

  describe "the reaper" do
    it "is off unless something arms it, so a poll on its own deletes nothing" do
      loaded_app(nil)
      _(client.removed).must_be_empty
      _(store.sections.all.map(&:id)).must_include "f23c8673"
    end

    # A reaped row has to be dropped on the way to the store, not after it
    # gets there: `update` would fold it straight back into the entry table
    # and the row would reappear for a poll. That holds for the early
    # hand-over too, the one that goes up before `claude rm` runs.
    it "keeps what it reaped out of the frame" do
      reaper = Class.new {
        def due(_sessions, _now) = %w[f23c8673]

        def sweep(_sessions, _now) = %w[f23c8673]

        def log_path = File::NULL
      }.new
      a = ClaudeInbox::App.new(
        client: client, store: store, reaper: reaper,
        pull_requests: ClaudeInbox::PullRequests.new(jobs_dir: fixture_path("jobs"), cache_path: nil, resolved_path: nil, gh: nil),
        jobs_dir: fixture_path("jobs"),
        out: out, input: StringIO.new, color: false
      )
      a.send(:poll_once)
      a.send(:drain_queue)

      _(store.sections.all.map(&:id)).wont_include "f23c8673"
      _(store.entry("f23c8673")).must_be_nil
    end

    it "brings a row back when its reap was refused" do
      reaper = Class.new {
        def due(_sessions, _now) = %w[f23c8673]

        def sweep(_sessions, _now) = []

        def log_path = File::NULL
      }.new
      a = ClaudeInbox::App.new(
        client: client, store: store, reaper: reaper,
        pull_requests: ClaudeInbox::PullRequests.new(jobs_dir: fixture_path("jobs"), cache_path: nil, resolved_path: nil, gh: nil),
        jobs_dir: fixture_path("jobs"),
        out: out, input: StringIO.new, color: false
      )
      a.send(:poll_once)
      a.send(:drain_queue)

      _(store.sections.all.map(&:id)).must_include "f23c8673"
    end
  end
end
