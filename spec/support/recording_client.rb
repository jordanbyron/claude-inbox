# frozen_string_literal: true

# The fixture's sessions, with every action recorded rather than run.
# `hold` makes the next spawn or rm wait for `release`; `fail_spawn` makes
# spawns raise the way a refusing CLI does, until it is given nil; `rm`
# refuses the ids in `refuse`, the way the CLI refuses a worktree holding
# unpushed commits.
class RecordingClient < ClaudeInbox::FixtureClient
  attr_reader :removed, :stopped, :attached, :spawns

  def initialize(path = File.join(Drivers::FIXTURES, "agents.json"), refuse: [], **opts)
    super(path, **opts)
    @refuse = refuse
    @removed = []
    @stopped = []
    @attached = []
    @spawns = []
  end

  def hold = @gate = Queue.new

  def release = @gate&.push(true)

  def fail_spawn(message) = @spawn_error = message

  def rm(id)
    @gate&.pop
    raise ClaudeInbox::AgentsClient::Error, "rm failed: worktree has unpushed commits" if @refuse.include?(id)
    removed << id
    true
  end

  def stop(id)
    stopped << id
    true
  end

  def attach(id) = attached << id

  def spawn(**opts)
    spawns << opts
    @gate&.pop
    raise ClaudeInbox::AgentsClient::Error, @spawn_error if @spawn_error
    "deadbeef"
  end
end
