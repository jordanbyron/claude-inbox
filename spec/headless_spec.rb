# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeInbox::Headless do
  let(:now) { Time.at(1_789_600_000) }
  let(:client) { instance_double(ClaudeInbox::AgentsClient) }

  it "updates the store from each poll and writes the snapshot" do
    Dir.mktmpdir do |dir|
      queue = Queue.new
      store = ClaudeInbox::Store.new(path: File.join(dir, "state.json"), clock: -> { now })
      snapshot = ClaudeInbox::Snapshot.new(path: File.join(dir, "snapshot.json"))
      headless = described_class.new(client: client, store: store, snapshot: snapshot, queue: queue,
        lock_path: File.join(dir, "headless.lock"), clock: -> { now })
      queue << [:sessions, [session(id: "a", state: "blocked")]]
      headless.step
      data = JSON.parse(File.read(File.join(dir, "snapshot.json")))
      expect(data["sections"]["needs_you"].map { |r| r["id"] }).to eq(%w[a])
      expect(store.sections.needs_you.map(&:id)).to eq(%w[a])
    end
  end

  it "runs once per machine: a second one finds the lock held and returns false" do
    Dir.mktmpdir do |dir|
      lock = File.join(dir, "headless.lock")
      holder = File.open(lock, File::RDWR | File::CREAT, 0o600)
      expect(holder.flock(File::LOCK_EX | File::LOCK_NB)).to eq(0)
      headless = described_class.new(client: client, store: ClaudeInbox::Store.new(path: nil), lock_path: lock)
      expect(headless.run).to be(false)
    ensure
      holder&.close
    end
  end
end
