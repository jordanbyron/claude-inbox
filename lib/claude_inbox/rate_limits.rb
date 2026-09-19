# frozen_string_literal: true

require "json"

module ClaudeInbox
  # The subscription's 5-hour and 7-day usage, read from
  # ~/.claude/rate_limits.json. Nothing writes that file but the user's own
  # status line script (README, "Usage"): `claude agents --json` says nothing
  # about limits and there is no CLI command for them, but every session hands
  # its status line a `rate_limits` object on each turn, so a one-line tee
  # there is the only source that costs no API calls. No file, or a file
  # nobody has touched in STALE_AFTER, reads as nothing to show.
  class RateLimits
    DEFAULT_PATH = File.join(Dir.home, ".claude", "rate_limits.json")
    STALE_AFTER = 15 * 60

    def initialize(path: DEFAULT_PATH)
      @path = path
      @mtime = nil
      @data = nil
    end

    # "usage 5h 23% · 7d 41%", or nil. Parses only when the file has changed,
    # since render asks several times a second.
    def label(now = Time.now)
      mtime = File.mtime(@path)
      return nil if now - mtime > STALE_AFTER
      @data = parse if mtime != @mtime
      @mtime = mtime
      @data
    rescue SystemCallError
      @mtime = @data = nil
    end

    private

    def parse
      hash = JSON.parse(File.read(@path))
      parts = {"five_hour" => "5h", "seven_day" => "7d"}.filter_map do |key, word|
        pct = hash.dig(key, "used_percentage")
        "#{word} #{pct.round}%" if pct.is_a?(Numeric)
      end
      "usage " + parts.join(" · ") unless parts.empty?
    rescue JSON::ParserError, TypeError
      nil
    end
  end
end
