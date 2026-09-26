# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"
require "minitest/spec"
require "stringio"
require_relative "../lib/claude_inbox"
require_relative "../lib/claude_inbox/renderer"
require_relative "../lib/claude_inbox/vt_screen"
require_relative "../lib/claude_inbox/keymap"

module Fixtures
  DIR = File.expand_path("fixtures", __dir__)

  def fixture_path(name) = File.join(DIR, name)

  def fixture_sessions = ClaudeInbox::FixtureClient.new(fixture_path("agents.json")).list

  def wait_for(timeout: 2)
    deadline = Time.now + timeout
    sleep 0.01 while !yield && Time.now < deadline
    yield
  end

  def session(**attrs)
    ClaudeInbox::Session.new(
      id: "abc12345", cwd: "/tmp/proj", kind: "background",
      started_at: Time.at(1_789_400_000), state: "working", name: "thing", **attrs
    )
  end
end

# Stands in for Terminal: a fixed size and the last frame painted, as text.
class ScreenTerminal
  attr_reader :lines

  def initialize(width: 80, height: 27)
    @size = [width, height]
    @lines = []
  end

  attr_reader :size

  def paint(lines) = @lines = lines.map { |l| ClaudeInbox::Text.strip_ansi(l) }

  def release = yield

  def enter = nil

  def restore = nil

  def resized = nil

  def invalidate = nil
end

# The fixture's sessions, with every action recorded rather than run.
# `hold` makes the next spawn or rm wait for `release`; `fail_spawn` makes
# spawns raise the way a refusing CLI does, until it is given nil; `rm`
# refuses the ids in `refuse`, the way the CLI refuses a worktree holding
# unpushed commits.
class RecordingClient < ClaudeInbox::FixtureClient
  attr_reader :removed, :stopped, :attached, :spawns

  def initialize(path = File.join(Fixtures::DIR, "agents.json"), refuse: [], **opts)
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

# A connection for the Remote specs: it reads the request it
# was given and keeps whatever is written back.
class FakeSocket
  attr_reader :written

  def initialize(request)
    @input = StringIO.new(request.b)
    @written = +"".b
  end

  def read_nonblock(size, exception: true) = @input.read_nonblock(size, exception: exception)

  def write(data) = @written << data.b
end

# What came back from Listener#handle or Start#call, parsed. `note` is
# Start's, for N.
Reply = Struct.new(:status, :headers, :body, :written, :note) do
  def json = JSON.parse(body)
end

PNG = "\x89PNG\r\n\x1A\n#{"\0" * 16}".b

Minitest::Spec.include Fixtures
