# frozen_string_literal: true

require "fileutils"
require_relative "subprocess"

module ClaudeInbox
  # Images a prompt can carry: a dropped file, or whatever is on the
  # clipboard. Both come back as a path for a TextBuffer chip to hold.
  module Images
    DEFAULT_DIR = File.join(Dir.home, ".config", "claude-inbox", "images")
    EXTENSIONS = %w[.png .jpg .jpeg .gif .webp .bmp .svg].freeze
    # Matches Store::REAP_AFTER: an image is useless once the session that carried it is reaped.
    KEEP_FOR = 14 * 24 * 3600

    Clipboard = Struct.new(:image, :text)

    # Saved images are pruned here, on the way in, because nothing else
    # knows when a session stopped needing its image. macOS only: osascript
    # ships with the OS, and PNG is the flavor a screenshot puts there.
    def self.from_clipboard(dir: DEFAULT_DIR, now: Time.now, run: Subprocess.method(:capture))
      FileUtils.mkdir_p(dir)
      prune(dir, now)
      path = File.join(dir, now.strftime("%Y%m%d-%H%M%S-%L.png"))
      return Clipboard.new(path, nil) if run.call("osascript", "-e", CLIPBOARD_PNG, path).success?
      text = run.call("pbpaste")
      Clipboard.new(nil, (text.success? && !text.out.empty?) ? text.out : nil)
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

    def self.prune(dir, now)
      Dir.glob(File.join(dir, "*.png")).each do |f|
        File.delete(f) if now - File.mtime(f) > KEEP_FOR
      rescue SystemCallError
        nil
      end
    end
    private_class_method :prune
  end
end
