# frozen_string_literal: true

require "socket"

# Codex's daemon socket for the Codex specs: a Unix socket that upgrades to
# WebSocket and answers JSON-RPC from `answers` (method => result, or a
# lambda of params), pushing a notification ahead of every reply as the
# real one does. Requests land in `requests`; `drop` hangs up on every
# open connection.
class FakeCodexDaemon
  attr_reader :path, :requests, :connections

  def initialize(dir, answers)
    @path = File.join(dir, "codex.sock")
    @answers = {"initialize" => {"userAgent" => "fake"}}.merge(answers)
    @requests = Queue.new
    @connections = 0
    @open = []
    @server = UNIXServer.new(@path)
    @thread = Thread.new { loop { serve(@server.accept) } }
  end

  def drop = @open.each(&:close).clear

  def stop
    @thread.kill
    drop
    @server.close
  end

  private

  def serve(io)
    @connections += 1
    @open << io
    Thread.new do
      head = +""
      head << io.readpartial(1) until head.end_with?("\r\n\r\n")
      io.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
      ws = ClaudeInbox::Codex::WebSocket.new(io, timeout: 5)
      loop do
        msg = JSON.parse(ws.read_text)
        @requests << msg
        ws.write_text(JSON.generate(method: "thread/status/changed", params: {threadId: "t", status: {type: "idle"}}))
        answer = @answers.fetch(msg["method"]) { {"error" => {"code" => -32601, "message" => "no #{msg["method"]}"}} }
        answer = answer.call(msg["params"]) if answer.respond_to?(:call)
        reply = (answer.is_a?(Hash) && answer.key?("error")) ? answer : {"result" => answer}
        ws.write_text(JSON.generate(id: msg["id"], **reply))
      end
    rescue ClaudeInbox::Codex::WebSocket::Error, IOError, SystemCallError
      nil
    end
  end
end
