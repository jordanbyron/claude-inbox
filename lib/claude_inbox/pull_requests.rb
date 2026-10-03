# frozen_string_literal: true

require "json"
require "time"
require_relative "records"
require_relative "subprocess"

module ClaudeInbox
  # A pull request tied to a session. `state` uses GitHub's vocabulary plus
  # DRAFT, the same as Claude Code's own cache: OPEN, DRAFT, MERGED, CLOSED,
  # or nil when nothing has told us yet. `resolved_at` is when it was merged
  # or closed, in epoch seconds, once gh has said.
  PullRequest = Struct.new(:number, :url, :state, :title, :resolved_at) do
    def short = number ? "##{number}" : url.to_s.sub(%r{\Ahttps?://(www\.)?}, "")

    def merged? = state == "MERGED"

    def closed? = state == "CLOSED"

    # Merged or closed: nothing more will happen to it.
    def resolved? = merged? || closed?

    def known? = !state.nil?

    # Nothing more to learn: resolved, and gh has said when.
    def final? = resolved? && !resolved_at.nil?

    # Resolved before `time`, so a session started then can only have mentioned it.
    def resolved_before?(time) = final? && resolved_at < time.to_i

    # Resolved at or after `time`, which is the only kind of resolution that
    # can answer a session started then.
    def resolved_since?(time) = final? && resolved_at >= time.to_i
  end

  # Finds the PRs a session is tied to and keeps their state fresh.
  #
  # Claude Code already does the hard part: the daemon scans each background
  # session's transcript for links and writes them to the session's job state
  # file, which JobState reads onto `job_state`; `claude agents --json` does
  # not expose them.
  # It is a link scan, so a session that merely mentions a PR gets it too.
  # Interactive sessions have no job file; for those the store's `pr` override
  # is the only source.
  #
  # State comes first from our own record of resolved PRs, then from
  # ~/.claude/gh-pr-status-cache.json (whatever Claude Code last saw), then
  # from `gh pr view` for PRs that are still open, at most once per
  # REFRESH_AFTER. A merged or closed PR never changes again, so once gh has
  # said so, and when, it is written to RESOLVED_PATH and never asked about
  # again. Claude Code's cache never says when, and says nothing at all about
  # most of a link scan's PRs: it only covers PRs its own sessions opened.
  #
  # `enrich` never touches gh; it is what stands between `claude agents` and
  # the first frame. `refresh` is the slow half, one network round trip per
  # open PR, and the poller calls it after the list has already gone up.
  class PullRequests
    REFRESH_AFTER = 60

    CLAUDE_DIR = File.join(Dir.home, ".claude")
    RESOLVED_PATH = File.join(Dir.home, ".config", "claude-inbox", "prs.json")

    def initialize(cache_path: File.join(CLAUDE_DIR, "gh-pr-status-cache.json"), resolved_path: RESOLVED_PATH,
      gh: "gh", clock: -> { Time.now })
      @cache_path = cache_path
      @resolved_path = resolved_path
      @gh = gh
      @clock = clock
      @known = {}      # url => PullRequest
      @checked_at = {} # url => epoch seconds of the last gh call
      @mutex = Mutex.new
    end

    # Each session with its `prs` set from what is already known, asking
    # nobody. The scanned links come off `job_state`, so a session without
    # one (interactive, or forgotten) has none; Sessions.load sees to the
    # order. `overrides` maps session key => url for links set by hand; an
    # override replaces the scanned list.
    def enrich(sessions, overrides)
      sessions.map do |s|
        urls = overrides[s.key] ? [overrides[s.key]] : (s.job_state&.pr_urls || [])
        s.with(prs: urls.map { |u| known(u) })
      end
    end

    # Asks gh about every PR on these sessions that is due. Returns the
    # sessions with the answers on their `prs` and whether any PR changed, so
    # the caller knows whether the list is worth publishing again. A merge
    # date alone counts: it is what lets a PR the cache called merged settle.
    def refresh(sessions)
      changed = false
      fresh = sessions.map do |s|
        s.with(prs: s.prs.map { |pr|
          status(pr.url).tap { |now| changed = true if now != pr }
        })
      end
      [fresh, changed]
    end

    # Best known state for a url, refreshed through gh when due.
    def status(url)
      @mutex.synchronize do
        pr = @known[url] ||= seed(url)
        return pr if pr.final? || !due?(url)
        @checked_at[url] = @clock.call.to_i
        fresh = fetch(url)
        return pr unless fresh
        remember(fresh) if fresh.final?
        @known[url] = fresh
      end
    end

    # Parse `gh pr view --json` output. Pure so it can be tested.
    def self.parse(url, json)
      h = JSON.parse(json)
      state = (h["state"] == "OPEN" && h["isDraft"]) ? "DRAFT" : h["state"]
      resolved_at = h["closedAt"] && Time.iso8601(h["closedAt"]).to_i
      PullRequest.new(number: h["number"], url: h["url"] || url, state: state, title: h["title"], resolved_at: resolved_at)
    rescue JSON::ParserError, ArgumentError
      nil
    end

    # Only an https://github.com/<owner>/<repo>/pull/<n> link makes sense here.
    def self.valid_url?(url)
      url.to_s.match?(%r{\Ahttps://github\.com/[^/\s]+/[^/\s]+/pull/\d+/?\z})
    end

    private

    # Best known state for a url without asking gh.
    def known(url)
      @mutex.synchronize { @known[url] ||= seed(url) }
    end

    def due?(url)
      @gh && @clock.call.to_i - @checked_at.fetch(url, 0) >= REFRESH_AFTER
    end

    def seed(url)
      number = url[%r{/pull/(\d+)}, 1]&.to_i
      cached = resolved[url] || claude_cache[url]
      PullRequest.new(number: cached&.dig("number") || number, url: url, state: cached&.dig("state"),
        title: cached&.dig("title"), resolved_at: cached&.dig("resolved_at"))
    end

    # Same shape as Claude Code's cache, so `seed` reads both alike.
    def resolved
      @resolved ||= Records.read(@resolved_path)
    end

    def claude_cache
      @claude_cache ||= Records.read(@cache_path)
    end

    # Under @mutex.
    def remember(pr)
      resolved[pr.url] = {"number" => pr.number, "state" => pr.state, "title" => pr.title, "resolved_at" => pr.resolved_at}
      return unless @resolved_path
      Records.save(@resolved_path, resolved)
    end

    def fetch(url)
      r = Subprocess.capture(@gh, "pr", "view", url, "--json", "number,state,isDraft,title,url,closedAt")
      r.success? ? self.class.parse(url, r.out) : nil
    rescue SystemCallError
      nil
    end
  end
end
