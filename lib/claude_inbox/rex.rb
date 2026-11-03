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
      return focus(tab["block_id"]) if tab
      cwd = (session.cwd && File.directory?(session.cwd)) ? ["-c", session.cwd] : []
      opened = rex("run", "--label", label, *cwd, "--json", command: attach_command(session))
      rex("window", "rename", JSON.parse(opened)["window_id"], session.display_name)
    end

    def focus(block) = rex("focus", block)

    # A tab starts in the login shell's environment, whose PATH can find
    # another ruby than the one running this inbox (docs/cli-quirks.md).
    def attach_command(session)
      [*(["env", "PATH=#{@path}"] if @path), @launcher, "attach", "--harness=#{session.harness}", *(["--cwd=#{session.cwd}"] if session.cwd),
        "--return-to=#{@block}", session.id]
    end

    private

    def blocks = JSON.parse(rex("block", "ls", "--json"))["blocks"]

    def rex(*args, command: [])
      r = @run.call(@bin, *args, "-s", @session, *(["--", *command] if command.any?))
      raise Error, "rex #{args.first}: #{r.err.strip}" unless r.success?
      r.out
    end
  end
end
