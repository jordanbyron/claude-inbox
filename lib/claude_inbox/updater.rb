# frozen_string_literal: true

require "fileutils"
require "json"
require "net/http"
require "rbconfig"
require_relative "../claude_inbox"
require_relative "mod"
require_relative "subprocess"

module ClaudeInbox
  # Finds and installs a newer claude-inbox: from a gem, the latest release on
  # rubygems.org; from a checkout, what main's tracking branch has. Every
  # collaborator is injectable so the spec touches neither network nor git.
  class Updater
    ROOT = File.expand_path("../..", __dir__)
    CACHE_PATH = File.join(Dir.home, ".config", "claude-inbox", "update.json")
    LATEST_URL = "https://rubygems.org/api/v1/versions/claude-inbox/latest.json"
    FRESH_FOR = 24 * 60 * 60
    TIMEOUT = 5

    # The check could not tell: rubygems.org or the remote is unreachable.
    class Error < StandardError; end

    # `kind` is :gem or :checkout. `behind` counts a checkout's commits and is
    # nil for a gem.
    Update = Data.define(:kind, :current, :latest, :behind) do
      def notice = (kind == :gem) ? "v#{latest} available" : "main is #{behind} behind"

      def installing
        (kind == :gem) ? "Installing claude-inbox #{latest} over #{current}..." : "main is #{behind} behind, fast-forwarding to #{latest}..."
      end
    end

    Applied = Data.define(:success, :output) do
      def success? = success
    end

    def self.fetch_url(url)
      uri = URI(url)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
        http.get(uri.request_uri)
      end
      raise Error, "#{uri.host} answered #{response.code}" unless response.is_a?(Net::HTTPSuccess)
      response.body
    rescue SystemCallError, SocketError, IOError, Timeout::Error, OpenSSL::SSL::SSLError => e
      raise Error, "#{uri.host} is unreachable: #{e.message}"
    end

    def initialize(checkout: Mod::CHECKOUT, root: ROOT, version: VERSION, cache_path: CACHE_PATH,
      run: Subprocess.method(:capture), fetch: Updater.method(:fetch_url),
      exec: ->(*argv) { Kernel.exec(*Subprocess.command(*argv)) }, clock: -> { Time.now })
      @checkout = checkout
      @root = root
      @version = version
      @cache_path = cache_path
      @run = run
      @fetch = fetch
      @exec = exec
      @clock = clock
    end

    def kind = @checkout ? :checkout : :gem

    # The newer version there is, or nil when this one is the latest. Asks the
    # network at most once a day unless forced: what it last heard is kept in
    # the cache file, and a check within the day compares against that.
    def check(force: false)
      known = force ? nil : fresh_cache
      latest = known || fetch_latest
      write_cache(latest) unless known
      compare(latest)
    end

    # What a check within the day found, without asking the network: nil
    # when it found nothing newer, or there was no check.
    def cached
      latest = fresh_cache
      compare(latest) if latest
    end

    # Installs the latest: `gem install`, or a fast-forward of main, refused
    # on another branch or a dirty tree rather than merged over. Success
    # drops the cache, so a launch that auto-updates cannot apply the same
    # version again and again should the launcher still resolve to this one.
    def apply
      applied = @checkout ? apply_checkout : install_gem
      FileUtils.rm_f(@cache_path) if applied.success?
      applied
    end

    # Replaces this process with a fresh launch on the same arguments. The
    # gem's binstub resolves to the newest installed version, and a checkout's
    # bin/claude-inbox runs whatever main now holds. The child's environment
    # is Subprocess's unbundled one, so a Gemfile.lock cannot pin the binstub
    # to the version just replaced.
    def relaunch(argv)
      launcher = @checkout ? File.join(@root, "bin", "claude-inbox") : "claude-inbox"
      @exec.call(launcher, *argv)
    end

    private

    def compare(latest) = @checkout ? checkout_update(latest) : gem_update(latest)

    def install_gem
      result = @run.call(Gem.ruby, File.join(RbConfig::CONFIG["bindir"], "gem"), "install", "claude-inbox")
      Applied.new(success: result.success?, output: result.out + result.err)
    end

    def gem_update(latest)
      return nil unless Gem::Version.new(latest) > Gem::Version.new(@version)
      Update.new(kind: :gem, current: @version, latest: latest, behind: nil)
    end

    def checkout_update(latest)
      behind = git("rev-list", "--count", "main..#{latest}").to_i
      return nil if behind.zero?
      Update.new(kind: :checkout, current: git("rev-parse", "--short", "main"), latest: latest[0, 7], behind: behind)
    end

    def fetch_latest
      return fetch_upstream if @checkout
      JSON.parse(@fetch.call(LATEST_URL)).fetch("version")
    rescue JSON::ParserError, KeyError
      raise Error, "rubygems.org sent something other than a version"
    end

    # Fetches the remote main tracks rather than a fixed URL, so a fork's
    # clone follows the fork.
    def fetch_upstream
      remote = git("config", "branch.main.remote") or raise Error, "main tracks no remote"
      fetched = @run.call("git", "-C", @root, "fetch", "--quiet", remote)
      raise Error, "git fetch #{remote} failed: #{fetched.err.strip}" unless fetched.success?
      git("rev-parse", "main@{upstream}") or raise Error, "main tracks no remote"
    end

    def apply_checkout
      branch = git("symbolic-ref", "--short", "HEAD")
      return Applied.new(success: false, output: "not on main (on #{branch})") unless branch == "main"
      return Applied.new(success: false, output: "the working tree is dirty") unless git("status", "--porcelain") == ""
      merged = @run.call("git", "-C", @root, "merge", "--ff-only", "--quiet", "main@{upstream}")
      Applied.new(success: merged.success?, output: merged.out + merged.err)
    end

    def git(*args)
      result = @run.call("git", "-C", @root, *args)
      result.out.strip if result.success?
    end

    def fresh_cache
      cache = JSON.parse(File.read(@cache_path))
      cache["latest"] if cache["kind"] == kind.to_s && @clock.call.to_i - cache["checked_at"].to_i < FRESH_FOR
    rescue SystemCallError, JSON::ParserError, TypeError
      nil
    end

    def write_cache(latest)
      FileUtils.mkdir_p(File.dirname(@cache_path))
      File.write(@cache_path, JSON.generate(checked_at: @clock.call.to_i, kind: kind, latest: latest))
    end
  end
end
