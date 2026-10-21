# frozen_string_literal: true

require "json"
require "time"
require_relative "agents_client"

module ClaudeInbox
  # A session's transcript, read from the end for when its last message was
  # sent. Only the `user` and `assistant` records are messages: the CLI
  # appends undated bookkeeping records long after a session has finished,
  # so the file's mtime says nothing.
  module Transcript
    MESSAGE_TYPES = %w[user assistant].freeze
    CHUNK = 64 * 1024

    module_function

    def enrich(sessions, home: Dir.home)
      sessions.map { |s| s.with(last_message_at: last_message_at(path_for(s, home))) }
    end

    def path_for(session, home)
      session.job_state&.transcript_path ||
        (session.cwd && session.session_id && AgentsClient.transcript_path(session.cwd, session.session_id, home: home))
    end

    def last_message_at(path)
      return nil unless path
      File.open(path, "rb") { |f| scan_back(f) }
    rescue SystemCallError
      nil
    end

    def scan_back(file)
      pos = file.size
      carry = +""
      while pos > 0
        step = [CHUNK, pos].min
        pos -= step
        file.seek(pos)
        lines = (file.read(step) + carry).split("\n", -1)
        carry = pos.zero? ? +"" : lines.shift
        lines.reverse_each do |line|
          at = message_time(line)
          return at if at
        end
      end
      nil
    end

    def message_time(line)
      return nil unless MESSAGE_TYPES.any? { |type| line.include?("\"type\":\"#{type}\"") }
      record = JSON.parse(line.force_encoding(Encoding::UTF_8))
      return nil unless MESSAGE_TYPES.include?(record["type"]) && record["timestamp"]
      Time.iso8601(record["timestamp"])
    rescue JSON::ParserError, ArgumentError
      nil
    end
  end
end
