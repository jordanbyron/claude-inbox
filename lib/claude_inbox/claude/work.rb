# frozen_string_literal: true

require "json"

module ClaudeInbox
  module Claude
    # Whether what a session started is still busy. The daemon's job file
    # lists what is open and drops a piece once it has finished, but keeps a
    # teammate that has reported and sits idle, so it cannot say busy. The
    # session's own transcript records every transition: a teammate's spawn,
    # its idle notice, the lead messaging it again, a background agent's or
    # shell's launch and the notification that closes it (docs/cli-quirks.md).
    # Each transcript is read from the start once, then only what has been
    # appended since, and only while the job lists something open.
    class Work
      def initialize
        @scans = {}
        @mutex = Mutex.new
      end

      # True when any of `pieces`, the job file's open work, is busy by the
      # transcript's account. A piece the transcript cannot place is busy:
      # the daemon says it is open, and a spinner that outstays its work is
      # the failure to prefer over a session that looks done while it runs.
      def busy?(pieces, transcript_path)
        return false if pieces.empty?
        return true unless transcript_path
        scan = @mutex.synchronize { (@scans[transcript_path] ||= Scan.new(transcript_path)).tap(&:advance) }
        pieces.any? { |piece| scan.busy?(piece) }
      end

      # One transcript's account of the work its session started.
      class Scan
        LAUNCHED = /background with ID: (\w+)|moved to the background \(ID: (\w+)\)/
        IDLE = /<teammate-message teammate_id="([^"]+)"[^>]*>\s*\{"type":"idle_notification"/
        CLOSED = %r{<task-notification>\s*<task-id>(\w+)</task-id>}

        def initialize(path)
          @path = path
          reset
        end

        def busy?(piece)
          key = @state.key?(piece.id) ? piece.id : @named[piece.label]
          @state.fetch(key, :busy) == :busy
        end

        # Reads what the session has appended. A transcript shorter than
        # last time has been replaced, and is read again from the start.
        def advance
          size = File.size(@path)
          reset if size < @offset
          return if size == @offset
          data = File.open(@path, "rb") do |f|
            f.seek(@offset)
            @carry + f.read
          end
          @offset = size
          lines = data.split("\n", -1)
          @carry = lines.pop
          lines.each { |line| record(line) }
        rescue SystemCallError
          nil
        end

        private

        def reset
          @offset = 0
          @carry = +""
          @pending = {}
          @state = {}
          @named = {}
        end

        def record(line)
          r = JSON.parse(line)
          content = r.dig("message", "content")
          case r["type"]
          when "assistant" then calls(content)
          when "user"
            results(content, r["toolUseResult"])
            notices(text_of(content))
          end
        rescue JSON::ParserError
          nil
        end

        def calls(content)
          each(content, "tool_use") do |x|
            input = x["input"] || {}
            case x["name"]
            when "Agent" then @pending[x["id"]] = [:spawn, input["name"], input["description"]]
            when "SendMessage" then @pending[x["id"]] = [:send, input["to"]]
            when "TaskStop" then @pending[x["id"]] = [:stop, input["task_id"] || input["shell_id"]]
            end
          end
        end

        # A teammate is known by its name and a background agent by the id
        # its launch answers with; the job file names a teammate only by
        # the description it was spawned with.
        def results(content, result)
          each(content, "tool_result") do |x|
            launched = text_of(x["content"])[LAUNCHED, 1] || text_of(x["content"])[LAUNCHED, 2]
            @state[launched] = :busy if launched
            kind, name, description = @pending.delete(x["tool_use_id"])
            next if kind.nil? || x["is_error"]
            result = {} unless result.is_a?(Hash)
            case kind
            when :spawn
              if result["status"] == "async_launched"
                @state[result["agentId"]] = :busy
              else
                name = result["name"] || name
                @state[name] = :busy
                @named[description] = name
              end
            when :send then @state[name] = :busy unless result["success"] == false
            when :stop then @state[name] = :idle
            end
          end
        end

        def notices(text)
          text.scan(IDLE) { |(name)| @state[name] = :idle } if text.include?("<teammate-message")
          text.scan(CLOSED) { |(id)| @state[id] = :idle } if text.include?("<task-notification>")
        end

        def each(content, type, &)
          return unless content.is_a?(Array)
          content.select { |x| x.is_a?(Hash) && x["type"] == type }.each(&)
        end

        def text_of(content)
          case content
          when String then content
          when Array then content.filter_map { |x| x["text"] if x.is_a?(Hash) }.join(" ")
          else ""
          end
        end
      end
    end
  end
end
