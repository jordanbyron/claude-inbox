# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeInbox::Records do
  it "reads a missing record, an unparsable one or no path at all as empty" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "store.json")
      expect(described_class.read(path)).to eq({})
      File.write(path, "{\"sessions\": ")
      expect(described_class.read(path)).to eq({})
      expect(described_class.read(nil)).to eq({})
    end
  end

  it "saves a record it can read back, making the directory and leaving no temp file" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config", "claude-inbox", "store.json")
      described_class.save(path, {"version" => 1, "sessions" => {"abc" => {"pinned" => true}}})
      expect(described_class.read(path)).to eq({"version" => 1, "sessions" => {"abc" => {"pinned" => true}}})
      expect(Dir.children(File.dirname(path))).to eq(["store.json"])
    end
  end

  it "replaces the whole record on a second save" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "switch.json")
      described_class.save(path, {"id" => "abc", "from" => "uuid-1"})
      described_class.save(path, {"id" => "def"})
      expect(described_class.read(path)).to eq({"id" => "def"})
    end
  end

  it "keeps a record saved with a mode at that mode, even over a wider file" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "listen.json")
      File.write(path, "{}")
      File.chmod(0o644, path)
      described_class.save(path, {"token" => "secret"}, perm: 0o600)
      expect(File.stat(path).mode & 0o777).to eq(0o600)
      expect(described_class.read(path)).to eq({"token" => "secret"})
    end
  end
end
