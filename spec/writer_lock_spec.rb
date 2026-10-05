# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeInbox::WriterLock do
  it "is held by one taker at a time" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "writer.lock")
      first = described_class.new(path: path)
      second = described_class.new(path: path)
      expect(first.take(role: "headless")).to be(true)
      expect(File.read(path)).to eq("headless #{Process.pid}")
      expect(second.take(role: "headless")).to be(false)
    end
  end

  it "never evicts an inbox: a second inbox runs without the lock" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "writer.lock")
      first = described_class.new(path: path)
      expect(first.take(role: "inbox")).to be(true)
      expect(described_class.new(path: path).take(role: "inbox")).to be(false)
      expect(described_class.new(path: path).take(role: "headless")).to be(false)
      expect(File.read(path)).to eq("inbox #{Process.pid}")
    end
  end

  it "takes over from a headless holder that is gone" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "writer.lock")
      File.write(path, "headless 999999999")
      expect(described_class.new(path: path).take(role: "inbox")).to be(true)
      expect(File.read(path)).to eq("inbox #{Process.pid}")
    end
  end

  it "is always held when disabled" do
    expect(described_class.disabled.take(role: "inbox")).to be(true)
  end
end
