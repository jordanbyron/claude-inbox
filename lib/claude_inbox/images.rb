# frozen_string_literal: true

require "fileutils"
require "securerandom"
require_relative "subprocess"

module ClaudeInbox
  # Images a prompt can carry: a dropped file, whatever is on the
  # clipboard, or the bytes a request sent. Each comes back as a path for
  # the prompt to mention.
  module Images
    DEFAULT_DIR = File.join(Dir.home, ".config", "claude-inbox", "images")
    EXTENSIONS = %w[.png .jpg .jpeg .gif .webp .bmp .svg].freeze
    # Matches Store::REAP_AFTER: an image is useless once the session that carried it is reaped.
    KEEP_FOR = 14 * 24 * 3600

    Clipboard = Struct.new(:image, :text)

    class Unsupported < StandardError; end

    # Bytes from a request carry no file name worth trusting, so the type
    # comes from the magic number at the front.
    MAGIC = {
      ".png" => /\A\x89PNG/n,
      ".jpg" => /\A\xFF\xD8\xFF/n,
      ".gif" => /\AGIF8/n,
      ".webp" => /\ARIFF.{4}WEBP/mn
    }.freeze

    # macOS only: osascript ships with the OS, and PNG is the flavor a
    # screenshot puts there.
    def self.from_clipboard(dir: DEFAULT_DIR, now: Time.now, run: Subprocess.method(:capture))
      FileUtils.mkdir_p(dir)
      prune(dir, now)
      path = File.join(dir, now.strftime("%Y%m%d-%H%M%S-%L.png"))
      return Clipboard.new(path, nil) if run.call("osascript", "-e", CLIPBOARD_PNG, path).success?
      text = run.call("pbpaste")
      Clipboard.new(nil, (text.success? && !text.out.empty?) ? text.out : nil)
    end

    # `index` orders the images one request brings; the random part keeps
    # two requests saving in the same millisecond apart. Readable by the
    # owner only: a photo can be anything.
    def self.save(bytes, dir: DEFAULT_DIR, now: Time.now, index: 1)
      data = bytes.b
      ext = MAGIC.find { |_, magic| magic.match?(data) }&.first
      raise Unsupported, "not a PNG, JPEG, GIF or WebP image" unless ext
      FileUtils.mkdir_p(dir)
      prune(dir, now)
      path = File.join(dir, "#{now.strftime("%Y%m%d-%H%M%S-%L")}-#{index}-#{SecureRandom.hex(3)}#{ext}")
      File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o600) { |f| f.write(data) }
      path
    end

    CLIPBOARD_PNG = <<~APPLESCRIPT
      on run argv
        set png to the clipboard as «class PNGf»
        set f to open for access POSIX file (item 1 of argv) with write permission
        write png to f
        close access f
      end run
    APPLESCRIPT

    # The path a dropped file arrives as, if it is an image: the terminal
    # pastes the path escaped the way a shell would want it, with a space
    # after, and only one of the extensions Claude Code itself attaches.
    def self.dropped(text)
      path = text.strip
      path = path[1...-1] if path.match?(/\A(["']).*\1\z/)
      path = path.gsub(/\\(.)/, '\1')
      return nil unless EXTENSIONS.include?(File.extname(path).downcase)
      File.file?(path) ? path : nil
    end

    # Pruned on the way in, because nothing else knows when a session
    # stopped needing its image.
    def self.prune(dir, now)
      Dir.glob(EXTENSIONS.map { |ext| File.join(dir, "*#{ext}") }).each do |f|
        File.delete(f) if now - File.mtime(f) > KEEP_FOR
      rescue SystemCallError
        nil
      end
    end
    private_class_method :prune
  end
end
