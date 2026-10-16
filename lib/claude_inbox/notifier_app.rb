# frozen_string_literal: true

require "fileutils"
require_relative "subprocess"

module ClaudeInbox
  # A copy of Homebrew's terminal-notifier.app under our own bundle id and
  # the web app's icon, since macOS draws a notification's icon from the
  # bundle that sends it and offers no way to override it.
  class NotifierApp
    DEFAULT_PATH = File.join(Dir.home, ".config", "claude-inbox", "notifier.app")
    ID = "dev.claude-inbox.notifier"
    # Both drawn from remote/icon.svg; the .icns through iconutil, from a
    # 16-1024px iconset of rsvg-convert renders.
    ICNS = File.join(__dir__, "remote", "icon.icns")
    PNG = File.join(__dir__, "remote", "icon.png")
    # Plain terminal-notifier carries the icon as a thumbnail instead.
    FALLBACK = ["terminal-notifier", "-contentImage", PNG].freeze

    def self.disabled = new(path: nil)

    def initialize(path: DEFAULT_PATH, run: Subprocess.method(:capture))
      @path = path
      @run = run
    end

    # Builds the copy when terminal-notifier's own app is new to us, and
    # sends one notification through `open`: macOS asks permission only of
    # an app LaunchServices started, never of its binary run from a shell.
    def prepare
      return unless @path && (app = source) && !current?(app)
      return unless build(app)
      @run.call("open", "-n", @path, "--args", "-title", "claude-inbox", "-message", "Notifications active.")
    end

    # The argv that sends one notification, short of its own flags.
    def command = (@path && current?(source)) ? [File.join(@path, "Contents", "MacOS", "terminal-notifier")] : FALLBACK

    private

    def source
      return @source if defined?(@source)
      r = @run.call("brew", "--prefix", "terminal-notifier")
      app = File.join(r.out.strip, "terminal-notifier.app") if r.success?
      @source = (app && File.directory?(app)) ? File.realpath(app) : nil
    end

    # The copy names the app it came from, whose Cellar path carries the
    # version, so an upgrade rebuilds it.
    def current?(app)
      app && File.read(stamp(@path)) == app
    rescue SystemCallError
      false
    end

    def stamp(bundle) = File.join(bundle, "Contents", "Resources", "source")

    # Built aside and moved into place, so `command` never sees half a copy.
    def build(app)
      tmp = "#{@path}.tmp"
      FileUtils.rm_rf(tmp)
      FileUtils.mkdir_p(File.dirname(tmp))
      FileUtils.cp_r(app, tmp)
      FileUtils.cp(ICNS, File.join(tmp, "Contents", "Resources", "claude-inbox.icns"))
      File.write(stamp(tmp), app)
      plist = File.join(tmp, "Contents", "Info.plist")
      steps = [
        ["plutil", "-replace", "CFBundleIdentifier", "-string", ID, plist],
        ["plutil", "-replace", "CFBundleName", "-string", "claude-inbox", plist],
        ["plutil", "-replace", "CFBundleIconFile", "-string", "claude-inbox", plist],
        ["codesign", "--force", "--sign", "-", tmp]
      ]
      unless steps.all? { |argv| @run.call(*argv).success? }
        FileUtils.rm_rf(tmp)
        return false
      end
      FileUtils.rm_rf(@path)
      File.rename(tmp, @path)
      true
    end
  end
end
