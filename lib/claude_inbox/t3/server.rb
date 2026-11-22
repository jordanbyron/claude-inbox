# frozen_string_literal: true

require "json"
require "net/http"
require "socket"
require "uri"
require_relative "../debug"
require_relative "../harnesses"
require_relative "../records"
require_relative "../subprocess"
require_relative "../codex/web_socket"

module ClaudeInbox
  module T3
    # The local T3 Code server, signed in to with a token of the inbox's own
    # (docs/cli-quirks.md).
    class Server
      class Error < Harnesses::Error; end

      class Unauthorized < Error; end

      TIMEOUT = 5
      PROTOCOL = 2
      HOME = File.join(Dir.home, ".t3")
      TOKEN_PATH = File.join(Dir.home, ".config", "claude-inbox", "t3-token.json")
      # Only what reading and acting on threads needs.
      SCOPES = %w[orchestration:read orchestration:operate].freeze
      TOKEN_TTL = "30d"

      def initialize(home: ENV.fetch("T3CODE_HOME", HOME), bin: nil, token_path: TOKEN_PATH, timeout: TIMEOUT)
        @home = home
        @bin = bin || [File.join(Dir.home, ".local", "bin", "t3")].find { |path| File.executable?(path) } || "t3"
        @token_path = token_path
        @timeout = timeout
      end

      attr_reader :bin, :home

      def installed? = File.directory?(@home)

      def shell = quietly("shell") { shell! }

      def shell!
        signed_in { |origin, token| JSON.parse(http(origin, Net::HTTP::Get.new("/api/orchestration/shell"), token)) }
      end

      def call(tag, payload = {}) = quietly(tag) { call!(tag, payload) }

      # A connection per call: the poll makes one a minute, an action one.
      def call!(tag, payload = {})
        signed_in do |origin, token|
          ticket = JSON.parse(http(origin, Net::HTTP::Post.new("/api/auth/websocket-ticket"), token))["ticket"]
          rpc(origin, ticket, tag, payload)
        end
      end

      private

      def quietly(what)
        yield
      rescue Error => e
        Debug.log("t3 #{what}: #{e.message}")
        nil
      end

      def signed_in
        origin = Records.read(File.join(@home, "userdata", "server-runtime.json"))["origin"] or raise Error, "T3 Code is not running"
        fresh = false
        token = Records.read(@token_path)["token"] || (fresh = issue)
        begin
          yield origin, token
        rescue Unauthorized
          raise if fresh
          fresh = true
          token = issue
          retry
        end
      rescue SystemCallError, IOError, Timeout::Error, JSON::ParserError, Codex::WebSocket::Error => e
        raise Error, "T3 Code: #{e.message}"
      end

      def issue
        scopes = SCOPES.flat_map { |s| ["--scope", s] }
        r = Subprocess.capture(@bin, "auth", "session", "issue", "--base-dir", @home, *scopes, "--label", "claude-inbox", "--ttl", TOKEN_TTL, "--token-only")
        raise Error, "t3 auth session issue failed: #{r.err.strip}" unless r.success? && !r.out.strip.empty?
        Records.save(@token_path, {"token" => r.out.strip}, perm: 0o600)
        r.out.strip
      end

      def http(origin, request, token)
        uri = URI(origin)
        request["Authorization"] = "Bearer #{token}"
        request["x-t3-orchestration-protocol"] = PROTOCOL.to_s
        response = Net::HTTP.start(uri.host, uri.port, open_timeout: @timeout, read_timeout: @timeout) { |h| h.request(request) }
        raise Unauthorized, "the token was refused" if response.code == "401"
        raise Error, "#{request.path} answered #{response.code}" unless response.is_a?(Net::HTTPSuccess)
        response.body
      end

      def rpc(origin, ticket, tag, payload)
        uri = URI(origin)
        ws = Codex::WebSocket.new(Socket.tcp(uri.host, uri.port, connect_timeout: @timeout), timeout: @timeout)
        ws.handshake(path: "/ws?#{URI.encode_www_form(orchestrationProtocol: PROTOCOL, wsTicket: ticket)}", host: "#{uri.host}:#{uri.port}")
        ws.write_text(JSON.generate(_tag: "Request", id: "1", tag: tag, payload: payload, headers: []))
        loop do
          message = JSON.parse(ws.read_text)
          done = (message.is_a?(Array) ? message : [message]).find { |m| m["_tag"] == "Exit" && m["requestId"] == "1" }
          return result(done["exit"]) if done
        end
      ensure
        ws&.close
      end

      def result(exit)
        return exit["value"] if exit["_tag"] == "Success"
        reasons = (exit["cause"] || []).map { |c| c.dig("error", "message") || c.dig("error", "_tag") || c["_tag"] }
        raise Error, reasons.compact.join("; ").then { |r| r.empty? ? "T3 Code refused" : r }
      end
    end
  end
end
