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
      pull_requests: ClaudeInbox::PullRequests.new(jobs_dir: fixture_path("jobs"), cache_path: nil, gh: nil),
      out: out, input: StringIO.new, color: false
    )
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
end
