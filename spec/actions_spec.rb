# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeInbox::Actions do
  let(:now) { Time.at(1_789_600_000) }
  let(:store) do
    ClaudeInbox::Store.new(path: nil, clock: -> { now }).tap { |s| s.update([session(id: "a", state: "done"), session(id: "b")]) }
  end
  let(:write) do
    lambda do |dir, name, request, age: 0|
      path = File.join(dir, name)
      File.write(path, request.is_a?(String) ? request : JSON.generate(request))
      File.utime(now - age, now - age, path)
    end
  end

  it "applies each request to the store and takes the file" do
    Dir.mktmpdir do |dir|
      write.call(dir, "1.json", {"action" => "settle", "id" => "a"})
      write.call(dir, "2.json", {"action" => "snooze", "id" => "b", "choice" => "h1"})
      write.call(dir, "3.json", {"action" => "pin", "id" => "b"})
      expect(described_class.new(dir: dir, clock: -> { now }).drain(store)).to eq(3)
      expect(Dir.children(dir)).to be_empty
      sections = store.sections
      expect(sections.settled.map(&:id)).to eq(%w[a])
      expect(sections.pinned.map(&:id)).to eq(%w[b])
      expect(store.entry("b")["wake_at"]).to eq(now.to_i + 3600)
    end
  end

  it "drops a verb it lacks or a bad snooze with the file" do
    Dir.mktmpdir do |dir|
      write.call(dir, "1.json", {"action" => "delete", "id" => "a"})
      write.call(dir, "2.json", {"action" => "snooze", "id" => "a", "choice" => "forever"})
      expect(described_class.new(dir: dir, clock: -> { now }).drain(store)).to eq(0)
      expect(Dir.children(dir)).to be_empty
      expect(store.sections.settled).to be_empty
    end
  end

  it "keeps a request for a session the last poll did not list until the grace runs out" do
    Dir.mktmpdir do |dir|
      actions = described_class.new(dir: dir, clock: -> { now })
      write.call(dir, "1.json", {"action" => "settle", "id" => "new", "at" => (now.to_i - 2) * 1000})
      write.call(dir, "2.json", {"action" => "pin", "id" => "new", "at" => (now.to_i - 2) * 1000})
      expect(actions.drain(store)).to eq(0)
      expect(Dir.children(dir).sort).to eq(%w[1.json 2.json])
      store.update([session(id: "a", state: "done"), session(id: "new", state: "done")])
      expect(actions.drain(store)).to eq(2)
      expect(store.sections.pinned.map(&:id)).to eq(%w[new])
      expect(store.entry("new")["settled_at"]).to eq(now.to_i)
      write.call(dir, "2.json", {"action" => "settle", "id" => "gone", "at" => (now.to_i - 60) * 1000})
      expect(actions.drain(store)).to eq(0)
      expect(Dir.children(dir)).to be_empty
    end
  end

  it "leaves a torn or empty file for the next pass while it is young, and drops it once old" do
    Dir.mktmpdir do |dir|
      actions = described_class.new(dir: dir, clock: -> { now })
      write.call(dir, "1.json", "{\"action\": \"set")
      write.call(dir, "2.json", "{}")
      expect(actions.drain(store)).to eq(0)
      expect(Dir.children(dir).sort).to eq(%w[1.json 2.json])
      write.call(dir, "1.json", "{\"action\": \"set", age: 60)
      write.call(dir, "2.json", "[]", age: 60)
      expect(actions.drain(store)).to eq(0)
      expect(Dir.children(dir)).to be_empty
    end
  end

  it "does nothing when disabled or without the directory" do
    expect(described_class.disabled.drain(store)).to eq(0)
    expect(described_class.new(dir: "/nonexistent/claude-inbox").drain(store)).to eq(0)
  end
end
