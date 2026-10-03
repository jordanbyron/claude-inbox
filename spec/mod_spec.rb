# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeInbox::Mod do
  it "links a stable path to the gem's mod folder and follows the folder when it moves" do
    Dir.mktmpdir do |dir|
      link = File.join(dir, "config", "mod")
      first = File.join(dir, "gem-1.0", "mod")
      second = File.join(dir, "gem-1.1", "mod")
      expect(described_class.link(link: link, dir: first)).to eq(link)
      expect(File.readlink(link)).to eq(first)
      described_class.link(link: link, dir: second)
      expect(File.readlink(link)).to eq(second)
    end
  end

  it "leaves a real folder of that name alone" do
    Dir.mktmpdir do |dir|
      link = File.join(dir, "mod")
      Dir.mkdir(link)
      described_class.link(link: link, dir: File.join(dir, "elsewhere"))
      expect(File.symlink?(link)).to be(false)
    end
  end

  it "ships beside lib" do
    expect(File.exist?(File.join(described_class::DIR, ".claude-plugin", "plugin.json"))).to be(true)
  end
end
