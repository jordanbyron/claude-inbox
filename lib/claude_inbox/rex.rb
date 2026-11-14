# frozen_string_literal: true

require "json"
require_relative "subprocess"

module ClaudeInbox
  # The Rex session an inbox runs in, when it runs in one: every session it
  # attaches to gets a tab of its own there, and the inbox keeps its pane.
  class Rex
    class Error < StandardError; end

    # A pane's label is how its tab is found again, by this or a later inbox.
    LABEL = "claude-inbox:"

    def self.from_env(env, launcher: "claude-inbox")
      session, block = env.values_at("REX_SESSION", "REX_BLOCK")
      return unless session && block
      bin = env["REX_BIN_DIR"] ? File.join(env["REX_BIN_DIR"], "rex") : "rex"
      new(session:, block:, launcher:, bin:, path: Subprocess::CHILD_ENV["PATH"])
    end

    def initialize(session:, block:, launcher:, bin: "rex", path: nil, run: Subprocess.method(:capture))
      @session = session
      @block = block
      @launcher = launcher
      @path = path
      @bin = bin
      @run = run
    end

    def open(session)
      label = LABEL + session.key
      tab = blocks.find { |b| b["label"] == label }
      return bring(tab["block_id"], tab["window_id"]) if tab
      cwd = (session.cwd && File.directory?(session.cwd)) ? ["-c", session.cwd] : []
      window = JSON.parse(rex("run", "--label", label, *cwd, "--json", command: attach_command(session)))["window_id"]
      rex("window", "rename", window, session.display_name)
      select(window)
    end

    def show(block)
      window = blocks.find { |b| b["block_id"] == block }&.fetch("window_id") or raise Error, "rex: no pane #{block}"
      bring(block, window)
    end

    # A tab starts in the login shell's environment, whose PATH can find
    # another ruby than the one running this inbox (docs/cli-quirks.md).
    def attach_command(session)
      [*(["env", "PATH=#{@path}"] if @path), @launcher, "attach", "--harness=#{session.harness}", *(["--cwd=#{session.cwd}"] if session.cwd),
        "--return-to=#{@block}", session.id]
    end

    private

    def bring(block, window)
      rex("focus", block)
      select(window)
    end

    def blocks = JSON.parse(rex("block", "ls", "--json"))["blocks"]

    # The server's focus leaves each app on the tab it was showing; only the
    # app can move itself, and only with Remote Control on (docs/cli-quirks.md).
    def select(window)
      apps.each { |app| call("-C", app, "do", "session.select", "session_id=#{@session}", "window_id=#{window}") }
    end

    def apps
      JSON.parse(call("client", "ls", "--json"))["clients"]
        .select { |c| c.dig("info", "kind") == "app" && c["session_ids"]&.include?(@session) }
        .map { |c| c["client_id"] }
    end

    def rex(*args, command: []) = call(*args, "-s", @session, *(["--", *command] if command.any?))

    def call(*args)
      r = @run.call(@bin, *args)
      raise Error, "rex: #{r.err.strip.delete_prefix("Error: ")}" unless r.success?
      r.out
    end
  end
end
