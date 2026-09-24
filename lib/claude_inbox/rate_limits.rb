# frozen_string_literal: true

require "json"

module ClaudeInbox
  # The subscription's 5-hour and 7-day usage, read from
  # ~/.claude/rate_limits.json. Nothing writes that file but the user's own
  # status line script (README, "Setup"): `claude agents --json` says nothing
  # about limits and there is no CLI command for them, but every session hands
  # its status line a `rate_limits` object on each turn, so a one-line tee
  # there is the only source that costs no API calls. No file, or a file
  # nobody has touched in STALE_AFTER, reads as nothing to show.
  class RateLimits
    DEFAULT_PATH = File.join(Dir.home, ".claude", "rate_limits.json")
    STALE_AFTER = 15 * 60
    SPANS = {"five_hour" => "5h", "seven_day" => "7d"}.freeze

    # `resets_at` is when the window rolls over, or nil if the file omits it.
    Window = Data.define(:span, :percent, :resets_at) do
      def initialize(span:, percent:, resets_at: nil) = super
    end

    def initialize(path: DEFAULT_PATH)
      @path = path
      @mtime = nil
      @data = nil
    end

    # The windows the file reports, each with a whole percent and its reset
    # time, or nil.
    # Parses only when the file has changed, since render asks several times
    # a second.
    def windows(now = Time.now)
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
      windows = SPANS.filter_map do |key, span|
        pct = hash.dig(key, "used_percentage")
        next unless pct.is_a?(Numeric)
        resets_at = hash.dig(key, "resets_at")
        Window.new(span, pct.round.clamp(0, 100), (Time.at(resets_at) if resets_at.is_a?(Numeric)))
      end
      windows unless windows.empty?
    rescue JSON::ParserError, TypeError
      nil
    end
  end
end
