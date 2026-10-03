# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeInbox::WriterLock do
  it "is held by one taker at a time, and free again on release" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "writer.lock")
      first = described_class.new(path: path)
      second = described_class.new(path: path)
      expect(first.take).to be(true)
      expect(first).to be_held
      expect(File.read(path)).to eq(Process.pid.to_s)
      expect(second.take).to be(false)
      expect(second).not_to be_held
      first.release
      expect(second.take).to be(true)
    end
  end

  it "takes over from a holder that is gone when asked to evict" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "writer.lock")
      File.write(path, "999999999")
      expect(described_class.new(path: path).take(evict: true)).to be(true)
    end
  end

  it "is always held when disabled" do
    expect(described_class.disabled.take).to be(true)
  end
end
