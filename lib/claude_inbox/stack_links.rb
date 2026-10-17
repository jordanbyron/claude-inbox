# frozen_string_literal: true

require "json"

module ClaudeInbox
  # The PRs a session opened with `gh stack submit`, read from its
  # transcript. The daemon links a session to one PR only, so a stack of
  # three shows as its first; this finds the rest.
  #
  # Transcripts run to megabytes and every poll asks, so each file is read
  # once and then only for what was appended since.
  class StackLinks
    # gh-stack's line for each PR it opens. Matched against a Bash result's
    # own stdout, at the start of a line, so a session that merely quotes
    # one doesn't count.
    CREATED = %r{^✓ Created PR #\d+ \((https://github\.com/[^/\s]+/[^/\s]+/pull/\d+)\)}

    def initialize
      @seen = {} # path => [bytes read, urls]
      @mutex = Mutex.new
    end

    # => the PR urls in creation order, [] for a missing or unreadable file.
    def urls(path)
      return [] unless path
      @mutex.synchronize do
        offset, urls = @seen.fetch(path, [0, []])
        offset, urls = 0, [] if File.size(path) < offset
        added = File.open(path, "r:UTF-8") { |f| f.seek(offset) && f.read }
        complete = added.include?("\n") ? added[..added.rindex("\n")] : ""
        @seen[path] = [offset + complete.bytesize, (urls + scan(complete)).uniq]
        @seen[path].last
      end
    rescue SystemCallError
      []
    end

    private

    def scan(text)
      text.each_line.select { |l| l.include?("Created PR #") }.flat_map do |line|
        stdout = JSON.parse(line).dig("toolUseResult", "stdout")
        stdout.is_a?(String) ? stdout.scan(CREATED).flatten : []
      rescue JSON::ParserError
        []
      end
    end
  end
end
