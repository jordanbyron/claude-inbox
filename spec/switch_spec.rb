# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeInbox::Switch do
  let(:now) { Time.at(1_789_600_000) }

  it "is a request for the session that asked, and hands over an attachable id once" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "switch.json")
      switch = described_class.new(path: path)
      expect(switch.requested_for?("uuid-1")).to be(false)
      ClaudeInbox::Records.save(path, {"id" => "abc12345", "from" => "uuid-1", "at" => now.to_i})
      expect(switch.requested_for?("uuid-1")).to be(true)
      expect(switch.requested_for?("uuid-2")).to be(false)
      expect(switch.requested_for?(nil)).to be(false)
      expect(switch.take(%w[abc12345 def67890])).to eq("abc12345")
      expect(switch.requested_for?("uuid-1")).to be(false)
      expect(switch.take(%w[abc12345])).to be_nil
    end
  end

  it "drops a request for a session nobody can attach to" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "switch.json")
      switch = described_class.new(path: path)
      ClaudeInbox::Records.save(path, {"id" => "terminal-uuid", "from" => "uuid-1", "at" => now.to_i})
      expect(switch.take(%w[abc12345])).to be_nil
      expect(File.exist?(path)).to be(false)
    end
  end

  it "treats an emptied file as no request" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "switch.json")
      File.write(path, "")
      expect(described_class.new(path: path).requested_for?("uuid-1")).to be(false)
    end
  end
end
