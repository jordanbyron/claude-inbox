# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeInbox::Claude::Work do
  let(:dir) { Dir.mktmpdir }
  let(:path) { File.join(dir, "lead.jsonl") }
  let(:work) { described_class.new }
  let(:piece) { ->(id, label = nil) { ClaudeInbox::Claude::JobState::Piece.new(id: id, label: label, kind: "agent") } }

  # Records the way the CLI writes them, cut to what the scan reads.
  let(:call) { ->(id, name, input) { {"type" => "assistant", "message" => {"content" => [{"type" => "tool_use", "id" => id, "name" => name, "input" => input}]}} } }
  let(:answer) { ->(id, text, result = nil) { {"type" => "user", "message" => {"content" => [{"type" => "tool_result", "tool_use_id" => id, "content" => text}]}, "toolUseResult" => result} } }
  let(:notice) { ->(text) { {"type" => "user", "message" => {"content" => text}} } }
  let(:idle_notice) { ->(name) { notice.call("<teammate-message teammate_id=\"#{name}\" color=\"green\">\n{\"type\":\"idle_notification\",\"from\":\"#{name}\",\"idleReason\":\"available\",\"result\":\"done\"}\n</teammate-message>") } }
  let(:closed) { ->(id) { notice.call("<task-notification>\n<task-id>#{id}</task-id>\n<status>completed</status>\n</task-notification>") } }
  let(:append) { ->(*records) { File.write(path, records.map { |r| JSON.generate(r) }.join("\n") + "\n", mode: "a") } }

  after { FileUtils.remove_entry(dir) }

  it "follows a teammate from its spawn through idle notices and messages, by the description the job file names it with" do
    append.call(call.call("t1", "Agent", {"name" => "scout", "description" => "Scout the repo", "prompt" => "go"}),
      answer.call("t1", "Spawned successfully.", {"name" => "scout", "agentId" => "scout@session-x"}))
    scout = [piece.call("tz9", "Scout the repo")]
    expect(work.busy?(scout, path)).to be(true)

    append.call(idle_notice.call("scout"))
    expect(work.busy?(scout, path)).to be(false)

    append.call(call.call("t2", "SendMessage", {"to" => "scout", "message" => "more"}), answer.call("t2", "sent", {"success" => true}))
    expect(work.busy?(scout, path)).to be(true)

    append.call(idle_notice.call("scout"),
      call.call("t3", "SendMessage", {"to" => "scout", "message" => "more"}),
      answer.call("t3", "not sent", {"success" => false, "message" => "No agent named 'scout' is reachable."}))
    expect(work.busy?(scout, path)).to be(false)
  end

  it "follows a background agent by the id its launch answers with, until its notification" do
    append.call(call.call("t1", "Agent", {"description" => "Build it", "run_in_background" => true, "prompt" => "go"}),
      answer.call("t1", "Async agent launched successfully.", {"isAsync" => true, "status" => "async_launched", "agentId" => "a1b2c3"}))
    expect(work.busy?([piece.call("a1b2c3", "Build it")], path)).to be(true)
    append.call(closed.call("a1b2c3"))
    expect(work.busy?([piece.call("a1b2c3", "Build it")], path)).to be(false)
  end

  it "follows a background shell from its launch until its notification or a stop" do
    append.call(call.call("t1", "Bash", {"command" => "sleep 9", "run_in_background" => true}),
      answer.call("t1", "Command running in background with ID: b1."),
      call.call("t2", "Bash", {"command" => "sleep 9"}),
      answer.call("t2", "Command did not complete within its timeout and was moved to the background (ID: b2). Output is being written to: /x"))
    expect(work.busy?([piece.call("b1")], path)).to be(true)
    expect(work.busy?([piece.call("b2")], path)).to be(true)

    append.call(closed.call("b1"), call.call("t3", "TaskStop", {"task_id" => "b2"}), answer.call("t3", "stopped"))
    expect(work.busy?([piece.call("b1")], path)).to be(false)
    expect(work.busy?([piece.call("b2")], path)).to be(false)
    expect(work.busy?([piece.call("b1"), piece.call("b2")], path)).to be(false)
  end

  it "calls a piece busy when the transcript cannot place it, is missing, or is not named" do
    append.call(idle_notice.call("scout"))
    expect(work.busy?([piece.call("unknown", "Never spawned")], path)).to be(true)
    expect(work.busy?([piece.call("x")], File.join(dir, "gone.jsonl"))).to be(true)
    expect(work.busy?([piece.call("x")], nil)).to be(true)
    expect(work.busy?([], nil)).to be(false)
  end

  it "reads only what was appended, waits for a cut-off line, and starts over on a replaced transcript" do
    append.call(call.call("t1", "Agent", {"name" => "scout", "description" => "Scout", "prompt" => "go"}), answer.call("t1", "Spawned successfully.", {"name" => "scout"}))
    scout = [piece.call("tz9", "Scout")]
    expect(work.busy?(scout, path)).to be(true)

    half = JSON.generate(idle_notice.call("scout"))
    File.write(path, half[0, 40], mode: "a")
    expect(work.busy?(scout, path)).to be(true)
    File.write(path, half[40..] + "\n", mode: "a")
    expect(work.busy?(scout, path)).to be(false)

    File.write(path, JSON.generate(call.call("t1", "Agent", {"name" => "scout", "description" => "Scout", "prompt" => "go"})) + "\n" + JSON.generate(answer.call("t1", "Spawned successfully.", {"name" => "scout"})) + "\n")
    expect(work.busy?(scout, path)).to be(true)
  end

  it "skips a line it cannot parse and a spawn that failed" do
    File.write(path, "{not json\n", mode: "a")
    append.call(call.call("t1", "Agent", {"name" => "scout", "description" => "Scout", "prompt" => "go"}),
      {"type" => "user", "message" => {"content" => [{"type" => "tool_result", "tool_use_id" => "t1", "is_error" => true, "content" => "refused"}]}})
    expect(work.busy?([piece.call("tz9", "Scout")], path)).to be(true)
  end
end
