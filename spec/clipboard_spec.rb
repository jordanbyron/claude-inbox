# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe ClaudeInbox::Clipboard do
  let(:bin) { Dir.mktmpdir }
  # A stand-in tool that keeps what it was given, or refuses it.
  let(:install) do
    lambda do |name, script = "cat > \"$0.got\""|
      File.write(File.join(bin, name), "#!/bin/sh\n#{script}\n")
      File.chmod(0o755, File.join(bin, name))
    end
  end

  after { FileUtils.rm_rf(bin) }

  describe ".command" do
    it "is pbcopy on macOS" do
      install.call("pbcopy")
      expect(described_class.command(platform: "arm64-darwin24", path: bin)).to eq([File.join(bin, "pbcopy")])
    end

    it "prefers wl-copy elsewhere, then xclip on the clipboard selection" do
      install.call("xclip")
      expect(described_class.command(platform: "x86_64-linux", path: bin)).to eq([File.join(bin, "xclip"), "-selection", "clipboard"])
      install.call("wl-copy")
      expect(described_class.command(platform: "x86_64-linux", path: bin)).to eq([File.join(bin, "wl-copy")])
    end

    it "is nil when no tool is on PATH" do
      expect(described_class.command(platform: "x86_64-linux", path: bin)).to be_nil
    end
  end

  describe ".copy" do
    it "hands the text to the tool on stdin" do
      install.call("wl-copy")
      expect(described_class.copy("https://example.com/pull/1", platform: "linux", path: bin)).to be(true)
      expect(File.read(File.join(bin, "wl-copy.got"))).to eq("https://example.com/pull/1")
    end

    it "is false without a tool" do
      expect(described_class.copy("x", platform: "linux", path: bin)).to be(false)
    end

    it "raises when the tool refuses" do
      install.call("pbcopy", "echo nope >&2; exit 1")
      expect { described_class.copy("x", platform: "darwin", path: bin) }
        .to raise_error(described_class::Failed, "pbcopy failed: nope")
    end
  end
end
