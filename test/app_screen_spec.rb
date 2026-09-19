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
      pull_requests: ClaudeInbox::PullRequests.new(cache_path: nil, resolved_path: nil, gh: nil),
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
      a.instance_variable_get(:@poller).once
      a.send(:drain_queue)
      a.instance_variable_set(:@selected, selected)
    end
  end

  # `run` is what normally builds the pane and the logs thread behind it; a
  # rendered frame asks the pane what to paint, so tests that render need one.
  def with_peek(a)
    a.instance_variable_set(:@peek, ClaudeInbox::Peek.new(ClaudeInbox::Logs.new(client)))
    a
  end

  # A row's screen line, found the same way the paint did it: by scanning
  # the row->item map render just built, rather than assuming a layout.
  def row_for(a, key)
    idx = a.instance_variable_get(:@row_items).index { |item| item&.key == key }
    idx + 1
  end

  it "hands a paste to the new-session form whole, and types it into the filter" do
    app.send(:handle_input, "/")
    app.send(:handle_input, "\e[200~thi\e[201~")
    _(app.instance_variable_get(:@filter)).must_equal "thi"
    app.send(:handle_input, "\e")
    app.send(:handle_input, "n")
    app.send(:handle_input, "\e[200~one\ntwo\e[201~")
    _(app.instance_variable_get(:@modal).values[:prompt]).must_equal "one\ntwo"
  end

  describe "clicking a row" do
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
      store.settle("b03695b1")
      a.send(:render)
      row = row_for(a, :settled)

      a.send(:handle_input, "\e[<0;5;#{row}M")

      _(a.instance_variable_get(:@expanded)[:settled]).must_equal true
    end

    it "ignores a click past the list column, such as one landing in the peek pane" do
      a = with_peek(loaded_app("f23c8673"))
      a.send(:toggle_peek)
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
    a = with_peek(loaded_app("f23c8673"))
    a.send(:render)
    keys = a.send(:filtered, store.sections).selectable_keys({})
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

  describe "alias and pull request editors" do
    it "seed their buffer from the store, so reopening shows what was saved" do
      a = loaded_app("f23c8673")
      store.set_alias("f23c8673", "auth spike")
      store.set_pr("f23c8673", "https://github.com/o/r/pull/7")

      a.send(:perform, :alias)
      _(a.instance_variable_get(:@modal).value).must_equal "auth spike"
      a.send(:handle_key, "\e")

      a.send(:perform, :link_pr)
      _(a.instance_variable_get(:@modal).value).must_equal "https://github.com/o/r/pull/7"
    end
  end
end
