# frozen_string_literal: true

require "socket"
require "fileutils"

# T3 Code's local server for the T3 specs, on a port of its own with its
# runtime file under `home`. It serves `shell` at /api/orchestration/shell,
# a ticket for the WebSocket, and answers each RPC from `answers` (tag =>
# value, a lambda of the payload, or an Exception for a failure). Only
# `token` is let in; `requests` holds what arrived, as [path or tag, body].
class FakeT3Server
  attr_reader :home, :requests
  attr_accessor :token, :shell

  def initialize(home, shell: {"projects" => [], "threads" => []}, answers: {}, token: "good")
    @home = home
    @shell = shell
    @answers = answers
    @token = token
    @requests = Queue.new
    @server = TCPServer.new("127.0.0.1", 0)
    FileUtils.mkdir_p(File.join(home, "userdata"))
    File.write(File.join(home, "userdata", "server-runtime.json"), JSON.generate(origin: "http://127.0.0.1:#{@server.addr[1]}"))
    @thread = Thread.new { loop { serve(@server.accept) } }
  end

  def stop
    @thread.kill
    @server.close
  end

  private

  def serve(io)
    Thread.new do
      handle(io)
    rescue IOError, SystemCallError
      nil
    ensure
      io.close unless io.closed?
    end
  end

  def handle(io)
    head = +""
    head << io.readpartial(1) until head.end_with?("\r\n\r\n")
    verb, target = head.lines.first.split
    path = target.split("?").first
    return upgrade(io, target) if path == "/ws"
    length = head[/^content-length: (\d+)/i, 1].to_i
    io.read(length) if length > 0
    @requests << [path, head[/^x-t3-orchestration-protocol: (\S+)/i, 1]]
    if head[/^authorization: Bearer (\S+)/i, 1] != @token
      reply(io, 401, {error: "unauthorized"})
    elsif verb == "GET" && path == "/api/orchestration/shell"
      reply(io, 200, @shell)
    elsif verb == "POST" && path == "/api/auth/websocket-ticket"
      reply(io, 200, {ticket: "ticket-#{@token}"})
    else
      reply(io, 404, {})
    end
  end

  def reply(io, status, body)
    json = JSON.generate(body)
    io.write("HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\nContent-Length: #{json.bytesize}\r\nConnection: close\r\n\r\n#{json}")
  end

  def upgrade(io, target)
    io.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
    ws = ClaudeInbox::Codex::WebSocket.new(io, timeout: 5)
    return unless target.include?("wsTicket=ticket-#{@token}") && target.include?("orchestrationProtocol=2")
    loop do
      msg = JSON.parse(ws.read_text)
      @requests << [msg["tag"], msg["payload"]]
      answer = @answers.fetch(msg["tag"]) { RuntimeError.new("no #{msg["tag"]}") }
      answer = answer.call(msg["payload"]) if answer.respond_to?(:call)
      exit = answer.is_a?(Exception) ? {_tag: "Failure", cause: [{_tag: "Fail", error: {_tag: "Refused", message: answer.message}}]} : {_tag: "Success", value: answer}
      ws.write_text(JSON.generate([{_tag: "Chunk", requestId: "other", values: []}, {_tag: "Exit", requestId: msg["id"], exit: exit}]))
    end
  rescue ClaudeInbox::Codex::WebSocket::Error, IOError, SystemCallError
    nil
  end
end
