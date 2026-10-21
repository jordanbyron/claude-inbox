# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeInbox::Transcript do
  let(:home) { Dir.mktmpdir }
  let(:path) { ClaudeInbox::AgentsClient.transcript_path("/Users/x/code/app", "u1", home: home) }
  let(:user) { {"type" => "user", "timestamp" => "2026-10-21T15:00:00.000Z", "message" => {"role" => "user", "content" => "hi"}} }
  let(:assistant) { {"type" => "assistant", "timestamp" => "2026-10-21T15:01:30.000Z", "message" => {"role" => "assistant", "content" => []}} }
  let(:bookkeeping) { [{"type" => "last-prompt", "prompt" => "hi"}, {"type" => "cost-state", "costUSD" => 1}, {"type" => "system", "timestamp" => "2026-10-21T16:00:00.000Z"}] }
  let(:write) do
    lambda do |records|
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, records.map { |r| JSON.generate(r) }.join("\n") + "\n")
    end
  end

  after { FileUtils.rm_rf(home) }

  it "reads the time of the last message past the records that carry none" do
    write.call([user, assistant, *bookkeeping])
    expect(described_class.last_message_at(path)).to eq(Time.utc(2026, 10, 21, 15, 1, 30))
  end

  it "reaches a message that sits behind more than one chunk of other records" do
    filler = {"type" => "attachment", "timestamp" => "2026-10-21T15:02:00.000Z", "attachment" => "x" * described_class::CHUNK}
    write.call([user, filler, filler, bookkeeping.first])
    expect(described_class.last_message_at(path)).to eq(Time.utc(2026, 10, 21, 15, 0, 0))
  end

  it "answers nil for a missing file, an empty one and one with no message yet" do
    expect(described_class.last_message_at(path)).to be_nil
    write.call([])
    expect(described_class.last_message_at(path)).to be_nil
    write.call(bookkeeping)
    expect(described_class.last_message_at(path)).to be_nil
    expect(described_class.last_message_at(nil)).to be_nil
  end

  it "finds a background session's transcript through its job file and an interactive one's through its directory" do
    write.call([user])
    named = File.join(home, "elsewhere.jsonl")
    File.write(named, JSON.generate(assistant) + "\n")
    bg = session(id: "abc12345", cwd: "/moved", session_id: "u1", job_state: ClaudeInbox::JobState.new("linkScanPath" => named))
    term = session(id: nil, kind: "interactive", cwd: "/Users/x/code/app", session_id: "u1", status: "busy")
    lost = session(id: nil, kind: "interactive", cwd: "/Users/x/other", session_id: "u2", status: "busy")
    at = described_class.enrich([bg, term, lost], home: home).map(&:last_message_at)
    expect(at).to eq([Time.utc(2026, 10, 21, 15, 1, 30), Time.utc(2026, 10, 21, 15, 0, 0), nil])
  end
end
