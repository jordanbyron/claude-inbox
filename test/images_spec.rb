# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/claude_inbox/images"
require "tmpdir"

describe ClaudeInbox::Images do
  def result(out, ok) = ClaudeInbox::Subprocess::Result.new(out, "", Struct.new(:success?).new(ok))

  def touch(dir, name, mtime: Time.now)
    File.join(dir, name).tap { |f|
      File.write(f, "x")
      File.utime(mtime, mtime, f)
    }
  end

  describe "a dropped path" do
    it "takes an image file, unescaped the way the terminal pasted it" do
      Dir.mktmpdir do |dir|
        shot = touch(dir, "Screen Shot.PNG")
        _(ClaudeInbox::Images.dropped("#{dir}/Screen\\ Shot.PNG ")).must_equal shot
        _(ClaudeInbox::Images.dropped("'#{shot}'")).must_equal shot
      end
    end

    it "leaves anything else as text" do
      Dir.mktmpdir do |dir|
        touch(dir, "notes.md")
        _(ClaudeInbox::Images.dropped("#{dir}/notes.md ")).must_be_nil
        _(ClaudeInbox::Images.dropped("#{dir}/missing.png")).must_be_nil
        _(ClaudeInbox::Images.dropped("look at this")).must_be_nil
      end
    end
  end

  describe "the clipboard" do
    it "saves an image to a file of its own and prunes stale ones" do
      Dir.mktmpdir do |dir|
        now = Time.at(1_789_400_000)
        old = touch(dir, "old.png", mtime: now - ClaudeInbox::Images::KEEP_FOR - 1)
        kept = touch(dir, "kept.png", mtime: now - 60)
        calls = []
        run = ->(*argv) {
          calls << argv
          result("", true)
        }
        clip = ClaudeInbox::Images.from_clipboard(dir: dir, now: now, run: run)
        _(clip.image).must_equal File.join(dir, now.strftime("%Y%m%d-%H%M%S-%L.png"))
        _(clip.text).must_be_nil
        _(calls.first[0..1]).must_equal ["osascript", "-e"]
        _(calls.first.last).must_equal clip.image
        _(File.exist?(old)).must_equal false
        _(File.exist?(kept)).must_equal true
      end
    end

    it "falls back to the clipboard's text, or nothing" do
      Dir.mktmpdir do |dir|
        run = ->(cmd, *) { (cmd == "pbpaste") ? result("hi\n", true) : result("", false) }
        clip = ClaudeInbox::Images.from_clipboard(dir: dir, run: run)
        _(clip.image).must_be_nil
        _(clip.text).must_equal "hi\n"
        empty = ->(*) { result("", false) }
        _(ClaudeInbox::Images.from_clipboard(dir: dir, run: empty).to_a).must_equal [nil, nil]
      end
    end
  end

  describe "a request's bytes" do
    # The first bytes of each type, which is all the sniffing reads.
    def samples = {
      ".png" => "\x89PNG\r\n\x1A\n\0\0\0\rIHDR".b,
      ".jpg" => "\xFF\xD8\xFF\xE0\0\x10JFIF\0".b,
      ".gif" => "GIF89a\x01\0\x01\0".b,
      ".webp" => "RIFF\x24\0\0\0WEBPVP8 ".b
    }

    it "saves each type under its own extension, readable by the owner only" do
      Dir.mktmpdir do |dir|
        now = Time.at(1_789_400_000, 123, :millisecond)
        samples.each.with_index(1) do |(ext, bytes), i|
          path = ClaudeInbox::Images.save(bytes, dir: dir, now: now, index: i)
          _(path).must_equal File.join(dir, "#{now.strftime("%Y%m%d-%H%M%S")}-123-#{i}#{ext}")
          _(File.binread(path)).must_equal bytes
          _(File.stat(path).mode & 0o777).must_equal 0o600
        end
      end
    end

    it "refuses anything else and writes nothing" do
      Dir.mktmpdir do |tmp|
        dir = File.join(tmp, "images")
        [Random.new(7).bytes(64), "BM\x3A\0\0\0".b, "<svg xmlns='http://www.w3.org/2000/svg'/>", ""].each do |bytes|
          _ { ClaudeInbox::Images.save(bytes, dir: dir) }.must_raise ClaudeInbox::Images::Unsupported
        end
        _(Dir.exist?(dir)).must_equal false
      end
    end

    it "prunes stale images of every type on the way in, and nothing else" do
      Dir.mktmpdir do |dir|
        now = Time.at(1_789_400_000)
        old = touch(dir, "old.jpg", mtime: now - 15 * 24 * 3600)
        kept = touch(dir, "kept.webp", mtime: now - 60)
        notes = touch(dir, "notes.txt", mtime: now - 15 * 24 * 3600)
        ClaudeInbox::Images.save(samples[".png"], dir: dir, now: now)
        _(File.exist?(old)).must_equal false
        _(File.exist?(kept)).must_equal true
        _(File.exist?(notes)).must_equal true
      end
    end
  end
end
