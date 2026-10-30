# frozen_string_literal: true

require "json"
require_relative "../session"
require_relative "../store"
require_relative "daemon"

module ClaudeInbox
  module Codex
    # The Codex adapter: lists the daemon's threads as Sessions. Read-only,
    # so its sessions carry no actions. Swap in FixtureClient for tests.
    class ThreadsClient
      # Without sourceKinds the daemon leaves out `codex exec` threads. The
      # daemon never forgets a thread, so the list stops where the reaper
      # would: at one quiet for longer than Store::REAP_AFTER.
      LIST = {sourceKinds: %w[cli vscode exec appServer], sortKey: "updated_at", limit: 100}.freeze

      # A thread's status, or the flag an active one waits on, in OSC 7501's words with the kind of block.
      STATES = {
        "waitingOnApproval" => ["blocked", "permission"], "waitingOnUserInput" => ["blocked", "question"],
        "active" => ["working"], "systemError" => ["error"], "idle" => ["idle"], "notLoaded" => ["idle"]
      }.freeze

      LINES = {"permission" => "waiting on approval", "question" => "waiting on input"}.freeze

      def initialize(daemon: Daemon.new, clock: -> { Time.now })
        @daemon = daemon
        @clock = clock
      end

      # => Array<Session>, newest first; empty when there is no daemon to ask.
      def list
        horizon = @clock.call - Store::REAP_AFTER
        sessions = []
        cursor = nil
        loop do
          result = @daemon.call("thread/list", {**LIST, cursor: cursor}.compact) or break
          page = self.class.sessions(result)
          sessions.concat(page.reject { |s| s.last_message_at && s.last_message_at < horizon })
          cursor = result["nextCursor"]
          break if cursor.nil? || page.empty? || page.last.last_message_at.to_i < horizon.to_i
        end
        sessions
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
