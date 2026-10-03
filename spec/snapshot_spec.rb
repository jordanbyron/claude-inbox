# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeInbox::Snapshot do
  let(:now) { Time.at(1_789_600_000) }
  let(:merged) { ClaudeInbox::PullRequest.new(number: 7, url: "https://github.com/o/r/pull/7", state: "MERGED", resolved_at: now.to_i - 60) }
  let(:sections) do
    entries = {"b" => {"last_state" => "done", "state_since" => now.to_i - 90, "alias" => "renamed", "wake_at" => "until_woken"}}
    ClaudeInbox::Store.sectionize([session(id: "a", state: "blocked", session_id: "u-a"), session(id: "b", state: "done", prs: [merged])], entries, now)
  end

  it "writes each section's rows as the screen shows them" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snapshot.json")
      described_class.new(path: path).write(sections, now)
      data = JSON.parse(File.read(path))
      expect(data["written_at"]).to eq(now.to_i)
      expect(data["sections"].keys).to eq(%w[pinned needs_you active snoozed settled])
      expect(data["sections"]["needs_you"].map { |r| r.slice("id", "session") }).to eq([{"id" => "a", "session" => "u-a"}])
      row = data["sections"]["snoozed"].first
      expect(row.slice("id", "label", "state", "actionable", "wake_at")).to eq(
        "id" => "b", "label" => "renamed", "state" => "done", "actionable" => true, "wake_at" => "until_woken"
      )
      expect(row["pr"]).to eq("short" => "#7", "state" => "merged", "url" => "https://github.com/o/r/pull/7")
    end
  end

  it "rewrites on a change and on the heartbeat, and otherwise leaves the file alone" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snapshot.json")
      snapshot = described_class.new(path: path)
      snapshot.write(sections, now)
      File.write(path, "stale")
      snapshot.write(sections, now + 1)
      expect(File.read(path)).to eq("stale")
      snapshot.write(sections, now + described_class::HEARTBEAT)
      expect(JSON.parse(File.read(path))["written_at"]).to eq(now.to_i + described_class::HEARTBEAT)
      File.write(path, "stale")
      snapshot.write(ClaudeInbox::Store.sectionize([session(id: "a")], {}, now), now + described_class::HEARTBEAT + 1)
      expect(JSON.parse(File.read(path))["sections"]["active"].map { |r| r["id"] }).to eq(%w[a])
    end
  end

  it "writes nothing when disabled" do
    expect { described_class.disabled.write(sections, now) }.not_to raise_error
  end
end
