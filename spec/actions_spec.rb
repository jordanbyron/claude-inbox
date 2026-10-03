# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeInbox::Actions do
  let(:now) { Time.at(1_789_600_000) }
  let(:store) do
    ClaudeInbox::Store.new(path: nil, clock: -> { now }).tap { |s| s.update([session(id: "a", state: "done"), session(id: "b")]) }
  end

  it "applies each request to the store and takes the file" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "1.json"), JSON.generate("action" => "settle", "id" => "a"))
      File.write(File.join(dir, "2.json"), JSON.generate("action" => "snooze", "id" => "b", "choice" => "h1"))
      File.write(File.join(dir, "3.json"), JSON.generate("action" => "pin", "id" => "b"))
      expect(described_class.new(dir: dir).drain(store)).to eq(3)
      expect(Dir.children(dir)).to be_empty
      sections = store.sections
      expect(sections.settled.map(&:id)).to eq(%w[a])
      expect(sections.pinned.map(&:id)).to eq(%w[b])
      expect(store.entry("b")["wake_at"]).to eq(now.to_i + 3600)
    end
  end

  it "drops a request for a session it does not know, a verb it lacks or a bad snooze" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "1.json"), JSON.generate("action" => "settle", "id" => "zz"))
      File.write(File.join(dir, "2.json"), JSON.generate("action" => "delete", "id" => "a"))
      File.write(File.join(dir, "3.json"), JSON.generate("action" => "snooze", "id" => "a", "choice" => "forever"))
      expect(described_class.new(dir: dir).drain(store)).to eq(0)
      expect(Dir.children(dir)).to be_empty
      expect(store.sections.settled).to be_empty
    end
  end

  it "leaves a file still being written for the next pass" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "1.json"), "{\"action\": \"set")
      expect(described_class.new(dir: dir).drain(store)).to eq(0)
      expect(Dir.children(dir)).to eq(%w[1.json])
    end
  end

  it "does nothing when disabled or without the directory" do
    expect(described_class.disabled.drain(store)).to eq(0)
    expect(described_class.new(dir: "/nonexistent/claude-inbox").drain(store)).to eq(0)
  end
end
