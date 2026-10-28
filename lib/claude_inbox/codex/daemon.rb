# frozen_string_literal: true

require "json"
require "socket"
require_relative "../../claude_inbox"
require_relative "../debug"
require_relative "../subprocess"
require_relative "web_socket"

module ClaudeInbox
  module Codex
    # A JSON-RPC connection to Codex's shared app-server daemon, the only
    # server that knows which threads are live (docs/cli-quirks.md). It
    # opens on the first call, stays open between calls and opens again
    # once it drops. With no codex or no daemon, every call answers nil.
    class Daemon
      # The daemon answered, with an error.
      class Error < StandardError; end

      TIMEOUT = 2

      def initialize(bin: "codex", socket: nil, timeout: TIMEOUT)
        @bin = bin
        @socket = socket
        @timeout = timeout
        @ws = nil
        @id = 0
        @lock = Mutex.new
      end

      # The result, or nil when there is no daemon or it would not answer.
      def call(method, params = {})
        call!(method, params)
      rescue Error => e
        Debug.log("codex #{method}: #{e.message}")
        nil
      end

      # The result, or Error with the daemon's reason, or with none to ask.
      # The poller and an action's thread share the one connection, so a
      # call holds it until its answer is in.
      def call!(method, params = {})
        @lock.synchronize { attempt(method, params) }
      end

      def close
        @ws&.close
        @ws = nil
      end

      private

      # A connection the daemon dropped since the last call gets one retry
      # on a fresh one.
      def attempt(method, params)
        fresh = @ws.nil?
        ws = (@ws ||= connect) or raise Error, "the Codex daemon is not running"
        request(ws, method, params)
      rescue WebSocket::Error, SystemCallError, IOError, JSON::ParserError => e
        close
        return attempt(method, params) unless fresh
        raise Error, e.message
      end

      def connect
        path = @socket || socket_path
        return unless path && File.exist?(path)
        ws = WebSocket.new(UNIXSocket.new(path), timeout: @timeout)
        ws.handshake
        request(ws, "initialize", clientInfo: {name: "claude-inbox", version: VERSION})
        ws
      rescue
        ws&.close
        raise
      end

      # `codex app-server daemon version` says whether the daemon is up and where its socket is.
      def socket_path
        r = Subprocess.capture(@bin, "app-server", "daemon", "version")
        return unless r.success?
        info = JSON.parse(r.out)
        info["socketPath"] if info["status"] == "running"
      rescue JSON::ParserError
        nil
      end

      # Notifications and anything else not answering this id are skipped.
      def request(ws, method, params)
        id = (@id += 1)
        ws.write_text(JSON.generate(id: id, method: method, params: params))
        loop do
          reply = JSON.parse(ws.read_text)
          next unless reply["id"] == id && !reply.key?("method")
          raise Error, reply.dig("error", "message").to_s if reply["error"]
          return reply["result"]
        end
      end
    end
  end
end
