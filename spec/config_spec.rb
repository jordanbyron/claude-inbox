# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeInbox::Config do
  subject(:argv) { described_class.argv(typed, path: path) }

  let(:dir) { Dir.mktmpdir }
  let(:path) { File.join(dir, "config") }
  let(:typed) { [] }

  after { FileUtils.remove_entry(dir) }

  context "without a config file" do
    let(:typed) { ["--no-color"] }

    it "is the typed arguments alone" do
      expect(argv).to eq(["--no-color"])
    end
  end

  context "with a config file" do
    before { File.write(path, contents) }

    context "and typed arguments" do
      let(:contents) { "--listen-lan\n" }
      let(:typed) { ["--listen=7500"] }

      it "puts the file's arguments before the typed ones" do
        expect(argv).to eq(["--listen-lan", "--listen=7500"])
      end
    end

    context "holding comments and blank lines" do
      let(:contents) do
        <<~CONFIG
          # arm the phone form
          --listen-lan --listen-allow-modes=default,plan  # no auto

          "--no-color"
        CONFIG
      end

      it "skips them and splits a line like a shell" do
        expect(argv).to eq(["--listen-lan", "--listen-allow-modes=default,plan", "--no-color"])
      end
    end

    context "holding a line that won't parse" do
      let(:contents) { "--listen-lan \"\n" }

      it "names the file" do
        expect { argv }.to raise_error(ArgumentError, /config: /)
      end
    end
  end
end
