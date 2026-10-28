# frozen_string_literal: true

require "json"
require_relative "../session"
require_relative "../store"
require_relative "../subprocess"
require_relative "daemon"

module ClaudeInbox
  module Codex
    # The Codex adapter: lists the daemon's threads as Sessions and acts on
    # them through it. Swap in FixtureClient for tests.
    class ThreadsClient
      # What the inbox can do to a thread: open it in `codex resume`,
      # interrupt its turn, delete it. Never reap it: `thread/delete` takes
      # unpushed work with it, where `claude rm` refuses.
      ACTIONS = %i[attach stop delete].freeze

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

      def initialize(daemon: Daemon.new, bin: "codex", clock: -> { Time.now })
        @daemon = daemon
        @bin = bin
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

      # Hands the terminal to `codex resume`, which joins the daemon's live
      # copy of the thread, and returns when it exits. False when it failed.
      # Run anywhere but the thread's directory, it first asks which to use.
      def attach(session)
        here = (session.cwd && File.directory?(session.cwd)) ? {chdir: session.cwd} : {}
        pid = Process.spawn(*Subprocess.command(@bin, "resume", session.id, **here))
        _, status = Process.wait2(pid)
        status.success? || !status.exited?
      end

      # Interrupts the turn under way. False when there is none. The thread
      # does not say which turn is running, so the newest is looked up.
      def stop(session)
        turn = @daemon.call!("thread/turns/list", threadId: session.id, sortDirection: "desc", limit: 1)["data"]&.first
        return false unless turn&.dig("status") == "inProgress"
        @daemon.call!("turn/interrupt", threadId: session.id, turnId: turn["id"])
        true
      end

      # The thread's rollout and its row in Codex's state go; there is no worktree to remove.
      def rm(session) = @daemon.call!("thread/delete", threadId: session.id)

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
          actions: ACTIONS,
          id: thread["id"],
          kind: "background",
          cwd: thread["cwd"],
          name: squish(thread["name"]) || preview,
          intent: preview,
          state: state,
          blocked_kind: blocked_kind,
          line: LINES[blocked_kind],
          started_at: time(thread["createdAt"]),
          last_message_at: time(thread["updatedAt"]),
          branch: thread.dig("gitInfo", "branch"),
          origin_url: thread.dig("gitInfo", "originUrl")
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

      # Stand-in child, as the Claude fixture's attach is.
      def attach(session) = system("sh", "-c", "printf 'fake codex resume %s\\npress enter to detach: ' \"$1\"; read -r _", "resume", session.id)

      def stop(_session) = true

      def rm(_session) = nil
    end
  end
end
