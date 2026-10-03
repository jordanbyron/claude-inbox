# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeInbox::Switch do
  it "hands over one request and is empty again" do
    Dir.mktmpdir do |dir|
      switch = described_class.new(path: File.join(dir, "switch.json"))
      expect(switch).not_to be_requested
      switch.request("abc12345", Time.at(1_789_600_000))
      expect(switch).to be_requested
      expect(switch.take).to eq("abc12345")
      expect(switch).not_to be_requested
      expect(switch.take).to be_nil
    end
  end

  it "ignores a request with no id" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "switch.json")
      File.write(path, "{}")
      expect(described_class.new(path: path).take).to be_nil
      expect(File.exist?(path)).to be(false)
    end
  end
end
