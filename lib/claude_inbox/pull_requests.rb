# frozen_string_literal: true

require "json"
require_relative "job_state"
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
  # session's transcript for links and writes them to the job's state file as
  # `children` (kind "pr"). `claude agents --json` does not expose that, so
  # JobState reads it. It is a link scan, so a session that merely mentions a
  # PR gets it too. Interactive sessions have no job file; for those the
  # store's `pr` override is the only source.
  #
  # State comes first from ~/.claude/gh-pr-status-cache.json (whatever Claude
  # Code last saw), then from `gh pr view` for PRs that are still open, at
  # most once per REFRESH_AFTER. A merged or closed PR never changes again,
  # so it is never asked about twice.
  class PullRequests
    REFRESH_AFTER = 60

    CLAUDE_DIR = File.join(Dir.home, ".claude")

    def initialize(jobs_dir: File.join(CLAUDE_DIR, "jobs"), cache_path: File.join(CLAUDE_DIR, "gh-pr-status-cache.json"),
      gh: "gh", clock: -> { Time.now })
      @jobs = JobState.new(jobs_dir: jobs_dir)
      @cache_path = cache_path
      @gh = gh
      @clock = clock
      @known = {}      # url => PullRequest
      @checked_at = {} # url => epoch seconds of the last gh call
      @mutex = Mutex.new
    end

    # Fills in `prs` on every session. `overrides` maps session key => url
    # for links set by hand; an override replaces the scanned list.
    def enrich(sessions, overrides = {})
      sessions.each do |s|
        urls = overrides[s.key] ? [overrides[s.key]] : linked(s.id)
        s.prs = urls.map { |u| status(u) }
      end
      sessions
    end

    # PR urls the daemon scanned out of a background session's transcript.
    def linked(id)
      @jobs.children(id).select { |c| c["kind"] == "pr" && c["href"] }.map { |c| c["href"] }
    end

    # Best known state for a url, refreshed through gh when due.
    def status(url)
      @mutex.synchronize do
        pr = @known[url] ||= seed(url)
        return pr if pr.resolved? || !due?(url)
        @checked_at[url] = @clock.call.to_i
        fresh = fetch(url)
        fresh ? (@known[url] = fresh) : pr
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
      cached = claude_cache[url]
      PullRequest.new(number: cached&.dig("number") || number, url: url, state: cached&.dig("state"), title: cached&.dig("title"))
    end

    def claude_cache
      @claude_cache ||= begin
        (@cache_path && File.exist?(@cache_path)) ? JSON.parse(File.read(@cache_path)) : {}
      rescue JSON::ParserError
        {}
      end
    end

    def fetch(url)
      r = Subprocess.capture(@gh, "pr", "view", url, "--json", "number,state,isDraft,title,url")
      r.success? ? self.class.parse(url, r.out) : nil
    rescue SystemCallError
      nil
    end
  end
end
