# frozen_string_literal: true

require "json"
require_relative "../session"
require_relative "../subprocess"
require_relative "daemon"

module ClaudeInbox
  module Codex
    # The Codex adapter: lists the daemon's threads as Sessions and acts on
    # them through it. Swap in FixtureClient for tests.
    class ThreadsClient
      # What the inbox can do to a thread: open it in `codex resume`, interrupt its turn, delete it.
      ACTIONS = %i[attach stop delete].freeze

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

      # The form's Permissions as thread/start's approval policy and sandbox.
      # "default" sends neither, so Codex's own config decides, as in its TUI.
      PERMISSIONS = {
        "read-only" => {approvalPolicy: "on-request", sandbox: "read-only"},
        "workspace-write" => {approvalPolicy: "on-request", sandbox: "workspace-write"},
        "full-access" => {approvalPolicy: "never", sandbox: "danger-full-access"}
      }.freeze
      PERMISSION_MODES = ["default", *PERMISSIONS.keys].freeze

      def initialize(daemon: Daemon.new, bin: "codex")
        @daemon = daemon
        @bin = bin
      end

      # => Array<Session>, empty when there is no daemon to ask.
      def list
        result = @daemon.call("thread/list", LIST)
        result ? self.class.sessions(result) : []
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

      # The daemon's models, "default" first, asked once it answers; none
      # without a daemon, which is also no way to start a thread.
      def models
        @models ||= @daemon.call("model/list")&.dig("data")&.then { |data| ["default", *data.reject { |m| m["hidden"] }.map { |m| m["id"] }] }
        @models || []
      end

      # Starts a thread and its first turn and returns the thread's id. A
      # thread with no turn is not listed, so the row shows once the turn
      # has started; the turn carries on after this connection closes.
      def spawn(prompt:, cwd:, model: nil, effort: nil, permission_mode: nil, images: [])
        thread = @daemon.call!("thread/start", {cwd: cwd, model: model, **PERMISSIONS.fetch(permission_mode, {})}.compact)["thread"]
        input = [{type: "text", text: prompt}, *images.map { |path| {type: "localImage", path: path} }]
        @daemon.call!("turn/start", {threadId: thread["id"], input: input, effort: effort}.compact)
        thread["id"]
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

      def models = %w[default gpt-6.1-sol]

      def spawn(**)
        sleep 0.5
        "01a18431-0b7e-7d40-9a51-2f6c1e0d4a10"
      end
    end
  end
end
