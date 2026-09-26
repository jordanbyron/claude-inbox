# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe ClaudeInbox::Images do
  let(:dir) { Dir.mktmpdir }

  after { FileUtils.rm_rf(dir) }

  describe "a dropped path" do
    it "takes an image file, unescaped the way the terminal pasted it" do
      shot = File.join(dir, "Screen Shot.PNG")
      FileUtils.touch(shot)
      expect(described_class.dropped("#{dir}/Screen\\ Shot.PNG ")).to eq(shot)
      expect(described_class.dropped("'#{shot}'")).to eq(shot)
    end

    it "leaves anything else as text" do
      FileUtils.touch(File.join(dir, "notes.md"))
      expect(described_class.dropped("#{dir}/notes.md ")).to be_nil
      expect(described_class.dropped("#{dir}/missing.png")).to be_nil
      expect(described_class.dropped("look at this")).to be_nil
    end
  end

  describe "the clipboard" do
    let(:succeeded) { ClaudeInbox::Subprocess::Result.new("", "", instance_double(Process::Status, success?: true)) }
    let(:pasted) { ClaudeInbox::Subprocess::Result.new("hi\n", "", instance_double(Process::Status, success?: true)) }
    let(:failed) { ClaudeInbox::Subprocess::Result.new("", "", instance_double(Process::Status, success?: false)) }

    it "saves an image to a file of its own and prunes stale ones" do
      now = Time.at(1_789_400_000)
      old = File.join(dir, "old.png")
      kept = File.join(dir, "kept.png")
      FileUtils.touch(old, mtime: now - described_class::KEEP_FOR - 1)
      FileUtils.touch(kept, mtime: now - 60)
      calls = []
      run = ->(*argv) {
        calls << argv
        succeeded
      }
      clip = described_class.from_clipboard(dir: dir, now: now, run: run)
      expect(clip.image).to eq(File.join(dir, now.strftime("%Y%m%d-%H%M%S-%L.png")))
      expect(clip.text).to be_nil
      expect(calls.first[0..1]).to eq(["osascript", "-e"])
      expect(calls.first.last).to eq(clip.image)
      expect(File.exist?(old)).to be(false)
      expect(File.exist?(kept)).to be(true)
    end

    it "falls back to the clipboard's text, or nothing" do
      run = ->(cmd, *) { (cmd == "pbpaste") ? pasted : failed }
      clip = described_class.from_clipboard(dir: dir, run: run)
      expect(clip.image).to be_nil
      expect(clip.text).to eq("hi\n")
      empty = ->(*) { failed }
      expect(described_class.from_clipboard(dir: dir, run: empty).to_a).to eq([nil, nil])
    end
  end

  describe "a request's bytes" do
    # The first bytes of each type, which is all the sniffing reads.
    let(:samples) {
      {
        ".png" => "\x89PNG\r\n\x1A\n\0\0\0\rIHDR".b,
        ".jpg" => "\xFF\xD8\xFF\xE0\0\x10JFIF\0".b,
        ".gif" => "GIF89a\x01\0\x01\0".b,
        ".webp" => "RIFF\x24\0\0\0WEBPVP8 ".b
      }
    }

    it "saves each type under its own extension, readable by the owner only" do
      now = Time.at(1_789_400_000, 123, :millisecond)
      samples.each.with_index(1) do |(ext, bytes), i|
        path = described_class.save(bytes, dir: dir, now: now, index: i)
        expect(File.dirname(path)).to eq(dir)
        expect(File.basename(path)).to match(/\A#{now.strftime("%Y%m%d-%H%M%S")}-123-#{i}-\h{6}#{ext}\z/)
        expect(File.binread(path)).to eq(bytes)
        expect(File.stat(path).mode & 0o777).to eq(0o600)
      end
    end

    it "keeps two images saved in the same millisecond apart" do
      now = Time.at(1_789_400_000)
      paths = 2.times.map { described_class.save(samples[".png"], dir: dir, now: now) }
      expect(paths.uniq.size).to eq(2)
      expect(paths.all? { |path| File.binread(path) == samples[".png"] }).to be(true)
    end

    it "refuses anything else and writes nothing" do
      images = File.join(dir, "images")
      [Random.new(7).bytes(64), "BM\x3A\0\0\0".b, "<svg xmlns='http://www.w3.org/2000/svg'/>", ""].each do |bytes|
        expect { described_class.save(bytes, dir: images) }.to raise_error(described_class::Unsupported)
      end
      expect(Dir.exist?(images)).to be(false)
    end

    it "prunes stale images of every type on the way in, and nothing else" do
      now = Time.at(1_789_400_000)
      old, kept, notes = %w[old.jpg kept.webp notes.txt].map { |name| File.join(dir, name) }
      FileUtils.touch([old, notes], mtime: now - 15 * 24 * 3600)
      FileUtils.touch(kept, mtime: now - 60)
      described_class.save(samples[".png"], dir: dir, now: now)
      expect(File.exist?(old)).to be(false)
      expect(File.exist?(kept)).to be(true)
      expect(File.exist?(notes)).to be(true)
    end
  end
end
