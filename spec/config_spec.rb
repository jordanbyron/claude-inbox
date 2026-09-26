# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeInbox::Config do
  let(:dir) { Dir.mktmpdir }
  let(:path) { File.join(dir, "config") }

  after { FileUtils.remove_entry(dir) }

  it "is the typed arguments alone without a config file" do
    expect(described_class.argv(["--no-color"], path: path)).to eq(["--no-color"])
  end

  it "puts the file's arguments before the typed ones" do
    File.write(path, "--listen-lan\n")
    expect(described_class.argv(["--listen=7500"], path: path)).to eq(["--listen-lan", "--listen=7500"])
  end

  it "skips comments and blank lines and splits a line like a shell" do
    config = <<~CONFIG
      # arm the phone form
      --listen-lan --listen-allow-modes=default,plan  # no auto

      "--no-color"
    CONFIG
    File.write(path, config)
    expect(described_class.argv([], path: path)).to eq(["--listen-lan", "--listen-allow-modes=default,plan", "--no-color"])
  end

  it "names the file when a line won't parse" do
    File.write(path, "--listen-lan \"\n")
    expect { described_class.argv([], path: path) }.to raise_error(ArgumentError, /config: /)
  end
end
