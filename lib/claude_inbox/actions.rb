# frozen_string_literal: true

require "fileutils"
require "json"

module ClaudeInbox
  # What another front end asks the inbox to do to a session: one file per
  # request under a directory, taken and applied here, so the triage rules
  # and the state file have one owner. A request for a session the last
  # poll did not list waits a little, since it may have just started; one
  # the store cannot honour after that, or a verb it lacks, is dropped.
  class Actions
    DEFAULT_DIR = File.join(Dir.home, ".config", "claude-inbox", "actions")
    VERBS = %w[settle wake pin snooze].freeze
    SNOOZES = %w[m15 h1 tomorrow_9am until_woken].freeze
    # A file still being written parses as nothing for milliseconds; a
    # session not yet polled appears within one poll.
    GRACE = 10

    def self.disabled = new(dir: nil)

    def initialize(dir: DEFAULT_DIR, clock: -> { Time.now })
      @dir = dir
      @clock = clock
    end

    # Applies every request on disk to `store` and returns how many it took.
    def drain(store)
      return 0 unless @dir && File.directory?(@dir)
      keys = store.sessions.select(&:actionable?).map(&:key)
      Dir.glob(File.join(@dir, "*.json")).sort.count do |path|
        request = parse(path)
        next false if request.nil?
        File.delete(path)
        apply(store, request, keys)
      end
    rescue Errno::ENOENT
      0
    end

    private

    # Nil leaves the file for the next pass: it is torn or early, and young.
    def parse(path)
      request = JSON.parse(File.read(path))
      request = {} unless request.is_a?(Hash)
      return request if File.mtime(path) < @clock.call - GRACE
      (request.key?("id") && request.key?("action")) ? request : nil
    rescue JSON::ParserError
      (File.mtime(path) < @clock.call - GRACE) ? {} : nil
    end

    def apply(store, request, keys)
      id = request["id"]
      return keep_young(request) unless keys.include?(id)
      return false unless VERBS.include?(request["action"])
      case request["action"]
      when "settle" then store.settle(id)
      when "wake" then store.wake(id)
      when "pin" then store.toggle_pin(id)
      when "snooze"
        return false unless SNOOZES.include?(request["choice"])
        store.snooze(id, request["choice"].to_sym)
      end
      true
    end

    # A request naming a session the store has not seen is written back for
    # a later pass, until it is older than the grace.
    def keep_young(request)
      at = request["at"].to_i / 1000
      return false if at <= 0 || Time.at(at) < @clock.call - GRACE
      File.write(File.join(@dir, "#{request["id"]}-#{at}.json"), JSON.generate(request))
      false
    end
  end
end
