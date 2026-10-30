# frozen_string_literal: true

require "json"
require "time"
require_relative "agents_client"

module ClaudeInbox
  # A session's transcript, read from the end for when its last message was
  # sent and for what its last few messages said. Only the `user` and
  # `assistant` records are messages: the CLI appends undated bookkeeping
  # records long after a session has finished, so the file's mtime says
  # nothing.
  #
  # Every poll asks for the time, and a transcript that ends in a long run
  # of other records costs a scan each time, so each file is read again only
  # once it has grown.
  class Transcript
    MESSAGE_TYPES = %w[user assistant].freeze
    CHUNK = 64 * 1024
    # The CLI's own notes to the model ride along as user records, which
    # the person never typed (docs/cli-quirks.md).
    REMINDER = %r{<system-reminder>.*?</system-reminder>}m

    def initialize
      @seen = {} # path => [size, time]
      @mutex = Mutex.new
    end

    def enrich(sessions, home: Dir.home)
      sessions.map { |s| s.with(last_message_at: last_message_at(path_for(s, home))) }
    end

    def last_message_at(path)
      return nil unless path
      @mutex.synchronize do
        size = File.size(path)
        seen_size, at = @seen[path]
        return at if seen_size == size
        at = File.open(path, "rb") { |f| scan_back(f) }
        @seen[path] = [size, at]
        at
      end
    rescue SystemCallError
      nil
    end

    def last_messages(session, count:, home: Dir.home)
      path = path_for(session, home) or return []
      said = []
      File.open(path, "rb") do |f|
        each_line_back(f) do |line|
          record = message(line) or next
          text = spoken(record)
          said.unshift([record["type"], text]) unless text.empty?
          break if said.size == count
        end
      end
      said
    rescue SystemCallError
      []
    end

    private

    def path_for(session, home)
      session.job_state&.transcript_path ||
        (session.cwd && session.session_id && AgentsClient.transcript_path(session.cwd, session.session_id, home: home))
    end

    def scan_back(file)
      each_line_back(file) do |line|
        at = message_time(line)
        return at if at
      end
      nil
    end

    def each_line_back(file)
      pos = file.size
      carry = +""
      while pos > 0
        step = [CHUNK, pos].min
        pos -= step
        file.seek(pos)
        lines = (file.read(step) + carry).split("\n", -1)
        carry = pos.zero? ? +"" : lines.shift
        lines.reverse_each { |line| yield line }
      end
    end

    def message_time(line)
      record = message(line) or return nil
      record["timestamp"] && Time.iso8601(record["timestamp"])
    rescue ArgumentError
      nil
    end

    def message(line)
      return nil unless MESSAGE_TYPES.any? { |type| line.include?("\"type\":\"#{type}\"") }
      record = JSON.parse(line.force_encoding(Encoding::UTF_8))
      record if MESSAGE_TYPES.include?(record["type"])
    rescue JSON::ParserError
      nil
    end

    def spoken(record)
      content = record.dig("message", "content")
      text = content.is_a?(String) ? content : Array(content).filter_map { |b| b["text"] if b.is_a?(Hash) && b["type"] == "text" }.join("\n")
      text.gsub(REMINDER, "").strip
    end
  end
end
