# frozen_string_literal: true

require "json"
require "time"

module ClaudeInbox
  module Claude
    # A session's transcript, read from the end for its last message: when
    # it was sent, and whether it ended the agent's turn. Only the `user`
    # and `assistant` records are messages: the CLI appends undated
    # bookkeeping records long after a session has finished, so the file's
    # mtime says nothing. A turn ends with an `assistant` record whose
    # `stop_reason` is `end_turn`; a prompt, a tool result or a tool call
    # last means the agent is mid-turn (docs/cli-quirks.md).
    #
    # Every poll asks, and a transcript that ends in a long run of other
    # records costs a scan each time, so each file is read again only once
    # it has grown.
    class Transcript
      MESSAGE_TYPES = %w[user assistant].freeze
      CHUNK = 64 * 1024

      # The last message: `at` is when it was sent, `over` whether it ended
      # the turn.
      Last = Data.define(:at, :over)

      def initialize
        @seen = {} # path => [size, Last]
        @mutex = Mutex.new
      end

      def enrich(sessions, home: Dir.home)
        sessions.map { |s| s.with(last_message_at: last_message_at(path_for(s, home))) }
      end

      def last_message_at(path) = last(path)&.at

      # Nil without a readable transcript or a message in it.
      def turn_over?(path) = last(path)&.over

      def last(path)
        return nil unless path
        @mutex.synchronize do
          size = File.size(path)
          seen_size, last = @seen[path]
          return last if seen_size == size
          last = File.open(path, "rb") { |f| scan_back(f) }
          @seen[path] = [size, last]
          last
        end
      rescue SystemCallError
        nil
      end

      private

      def path_for(session, home)
        session.transcript_path ||
          (session.cwd && session.session_id && AgentsClient.transcript_path(session.cwd, session.session_id, home: home))
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
            last = message(line)
            return last if last
          end
        end
        nil
      end

      def message(line)
        return nil unless MESSAGE_TYPES.any? { |type| line.include?("\"type\":\"#{type}\"") }
        record = JSON.parse(line.force_encoding(Encoding::UTF_8))
        return nil unless MESSAGE_TYPES.include?(record["type"]) && record["timestamp"]
        Last.new(at: Time.iso8601(record["timestamp"]), over: record["type"] == "assistant" && record.dig("message", "stop_reason") == "end_turn")
      rescue JSON::ParserError, ArgumentError
        nil
      end
    end
  end
end
