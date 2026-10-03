# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeInbox::Headless do
  let(:client) { instance_double(ClaudeInbox::AgentsClient) }

  it "exits at once while an inbox or another headless process holds the writer lock" do
    Dir.mktmpdir do |dir|
      lock = ClaudeInbox::WriterLock.new(path: File.join(dir, "writer.lock"))
      expect(lock.take).to be(true)
      headless = described_class.new(client: client, store: ClaudeInbox::Store.new(path: nil),
        lock: ClaudeInbox::WriterLock.new(path: File.join(dir, "writer.lock")))
      expect(headless.run).to be(false)
    end
  end
end
