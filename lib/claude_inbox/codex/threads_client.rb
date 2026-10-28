# frozen_string_literal: true

require "json"
require_relative "../session"
require_relative "daemon"

module ClaudeInbox
  module Codex
    # The Codex adapter: lists the daemon's threads as Sessions. Read-only,
    # so its sessions carry no actions. Swap in FixtureClient for tests.
    class ThreadsClient
      # Without sourceKinds the daemon leaves out `codex exec` threads. Fifty
      # is one page of the most recently updated, which is all a row could
      # want: nothing here reaps a Codex thread, so a longer page is history.
      LIST = {sourceKinds: %w[cli vscode exec appServer], sortKey: "updated_at", limit: 50}.freeze

      # A thread's status, or the flag an active one waits on, in OSC 7501's words with the kind of block.
      STATES = {
        "waitingOnApproval" => ["blocked", "permission"], "waitingOnUserInput" => ["blocked", "question"],
        "active" => ["working"], "systemError" => ["error"], "idle" => ["idle"], "notLoaded" => ["idle"]
      }.freeze

      LINES = {"permission" => "waiting on approval", "question" => "waiting on input"}.freeze

      def initialize(daemon: Daemon.new)
        @daemon = daemon
      end

      # => Array<Session>, empty when there is no daemon to ask.
      def list
        result = @daemon.call("thread/list", LIST)
        result ? self.class.sessions(result) : []
      end

      # A `thread/list` result as Sessions.
      def self.sessions(result)
        read_states = result["readStates"] || {}
        (result["data"] || []).map { |thread| session(thread, read_states[thread["id"]]) }
      end

      # A thread with a turn nobody has read is done, as a finished Claude
      # session is; the TUI never marks one read, so it stays done.
      def self.session(thread, read_state = nil)
        state, blocked_kind = state(thread["status"] || {}, unread: !read_state&.dig("firstUnread").nil?)
        preview = squish(thread["preview"])
        Session.new(
          harness: :codex,
          id: thread["id"],
          kind: "background",
          cwd: thread["cwd"],
          name: squish(thread["name"]) || preview,
          intent: preview,
          state: state,
          blocked_kind: blocked_kind,
          line: LINES[blocked_kind],
          started_at: time(thread["createdAt"]),
          last_message_at: time(thread["updatedAt"])
        )
      end

      def self.state(status, unread:)
        flag = STATES.keys.find { |k| status["activeFlags"]&.include?(k) } if status["type"] == "active"
        state, kind = STATES.fetch(flag || status["type"], ["idle"])
        [(state == "idle" && unread) ? "done" : state, kind]
      end

      def self.squish(text)
        words = text.to_s.split.join(" ")
        words unless words.empty?
      end

      def self.time(seconds) = seconds && Time.at(seconds)

      private_class_method :squish, :time
    end

    # Serves a committed `thread/list` result instead of the daemon; no file, no threads.
    class FixtureClient < ThreadsClient
      def initialize(path)
        @path = path
      end

      def list = File.exist?(@path) ? self.class.sessions(JSON.parse(File.read(@path))) : []
    end
  end
end
