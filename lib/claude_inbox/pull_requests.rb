# frozen_string_literal: true

require "json"
require_relative "job_state"
require_relative "records"
require_relative "subprocess"

module ClaudeInbox
  # A pull request tied to a session. `state` uses GitHub's vocabulary plus
  # DRAFT, the same as Claude Code's own cache: OPEN, DRAFT, MERGED, CLOSED,
  # or nil when nothing has told us yet.
  PullRequest = Struct.new(:number, :url, :state, :title) do
    def short = number ? "##{number}" : url.to_s.sub(%r{\Ahttps?://(www\.)?}, "")

    def merged? = state == "MERGED"

    def closed? = state == "CLOSED"

    # Merged or closed: nothing more will happen to it.
    def resolved? = merged? || closed?

    def known? = !state.nil?
  end

  # Finds the PRs a session is tied to and keeps their state fresh.
  #
  # Claude Code already does the hard part: the daemon scans each background
  # session's transcript for links and writes them to the session's job state
  # file, which JobState reads. `claude agents --json` does not expose them.
  # It is a link scan, so a session that merely mentions a PR gets it too.
  # Interactive sessions have no job file; for those the store's `pr` override
  # is the only source.
  #
  # State comes first from our own record of resolved PRs, then from
  # ~/.claude/gh-pr-status-cache.json (whatever Claude Code last saw), then
  # from `gh pr view` for PRs that are still open, at most once per
  # REFRESH_AFTER. A merged or closed PR never changes again, so it is never
  # asked about twice — and once gh has said so, it is written to
  # RESOLVED_PATH so the next launch does not ask either. Claude Code's cache
  # only covers PRs its own sessions opened, and a link scan picks up plenty
  # of others.
  #
  # `enrich` never touches gh; it is what stands between `claude agents` and
  # the first frame. `refresh` is the slow half, one network round trip per
  # open PR, and the poller calls it after the list has already gone up.
  class PullRequests
    REFRESH_AFTER = 60

    CLAUDE_DIR = File.join(Dir.home, ".claude")
    RESOLVED_PATH = File.join(Dir.home, ".config", "claude-inbox", "prs.json")

    def initialize(jobs_dir: JobState::DEFAULT_DIR, cache_path: File.join(CLAUDE_DIR, "gh-pr-status-cache.json"),
      resolved_path: RESOLVED_PATH, gh: "gh", clock: -> { Time.now })
      @jobs_dir = jobs_dir
      @cache_path = cache_path
      @resolved_path = resolved_path
      @gh = gh
      @clock = clock
      @known = {}      # url => PullRequest
      @checked_at = {} # url => epoch seconds of the last gh call
      @mutex = Mutex.new
    end

    # Fills in `prs` on every session from what is already known, asking
    # nobody. `overrides` maps session key => url for links set by hand; an
    # override replaces the scanned list.
    def enrich(sessions, overrides = {})
      sessions.each do |s|
        urls = overrides[s.key] ? [overrides[s.key]] : linked(s.id)
        s.prs = urls.map { |u| known(u) }
      end
      sessions
    end

    # Asks gh about every PR on these sessions that is due and writes the
    # answers back into `prs`. True when any state changed, so the caller
    # knows whether the list is worth publishing again.
    def refresh(sessions)
      changed = false
      sessions.each do |s|
        s.prs = s.prs.map { |pr|
          fresh = status(pr.url)
          changed = true if fresh.state != pr.state
          fresh
        }
      end
      changed
    end

    # PR urls the daemon scanned out of a background session's transcript.
    def linked(id) = JobState.read(id, jobs_dir: @jobs_dir)&.pr_urls || []

    # Best known state for a url without asking gh.
    def known(url)
      @mutex.synchronize { @known[url] ||= seed(url) }
    end

    # Best known state for a url, refreshed through gh when due.
    def status(url)
      @mutex.synchronize do
        pr = @known[url] ||= seed(url)
        return pr if pr.resolved? || !due?(url)
        @checked_at[url] = @clock.call.to_i
        fresh = fetch(url)
        return pr unless fresh
        remember(fresh) if fresh.resolved?
        @known[url] = fresh
      end
    end

    # Parse `gh pr view --json` output. Pure so it can be tested.
    def self.parse(url, json)
      h = JSON.parse(json)
      state = (h["state"] == "OPEN" && h["isDraft"]) ? "DRAFT" : h["state"]
      PullRequest.new(number: h["number"], url: h["url"] || url, state: state, title: h["title"])
    rescue JSON::ParserError
      nil
    end

    # Only an https://github.com/<owner>/<repo>/pull/<n> link makes sense here.
    def self.valid_url?(url)
      url.to_s.match?(%r{\Ahttps://github\.com/[^/\s]+/[^/\s]+/pull/\d+/?\z})
    end

    private

    def due?(url)
      @gh && @clock.call.to_i - @checked_at.fetch(url, 0) >= REFRESH_AFTER
    end

    def seed(url)
      number = url[%r{/pull/(\d+)}, 1]&.to_i
      cached = resolved[url] || claude_cache[url]
      PullRequest.new(number: cached&.dig("number") || number, url: url, state: cached&.dig("state"), title: cached&.dig("title"))
    end

    # Same shape as Claude Code's cache, so `seed` reads both alike.
    def resolved
      @resolved ||= read_json(@resolved_path)
    end

    def claude_cache
      @claude_cache ||= read_json(@cache_path)
    end

    def read_json(path)
      (path && File.exist?(path)) ? JSON.parse(File.read(path)) : {}
    rescue JSON::ParserError
      {}
    end

    # Under @mutex.
    def remember(pr)
      resolved[pr.url] = {"number" => pr.number, "state" => pr.state, "title" => pr.title}
      return unless @resolved_path
      Records.save(@resolved_path, resolved)
    end

    def fetch(url)
      r = Subprocess.capture(@gh, "pr", "view", url, "--json", "number,state,isDraft,title,url")
      r.success? ? self.class.parse(url, r.out) : nil
    rescue SystemCallError
      nil
    end
  end
end
