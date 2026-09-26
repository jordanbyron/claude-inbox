# frozen_string_literal: true

# A phone talking to the Listener: each request goes over as raw HTTP on a
# FakeSocket, and the answer written back comes out as a Reply. The token
# and Host it was given go on every request that doesn't name its own.
class Phone
  VIA = "192.168.1.30"

  def initialize(server, token: nil, host: nil)
    @server = server
    @token = token
    @host = host
  end

  def get(path, **opts) = request("GET", path, **opts)

  def start(params, **opts) = request("POST", "/api/sessions", params, **opts)

  def request(verb, path, body = nil, token: @token, host: @host, type: "application/json", headers: {})
    body = JSON.generate(body) if body && !body.is_a?(String)
    lines = ["#{verb} #{path} HTTP/1.1"]
    lines << "Host: #{host}" if host
    lines << "Authorization: Bearer #{token}" if token
    lines << "Content-Type: #{type}" if body && type
    lines << "Content-Length: #{body.bytesize}" if body
    headers.each { |name, value| lines << "#{name}: #{value}" }
    send_raw(lines.join("\r\n") + "\r\n\r\n" + body.to_s)
  end

  def send_raw(text)
    sock = FakeSocket.new(text)
    @server.handle(sock, via: VIA)
    head, body = sock.written.sub("HTTP/1.1 100 Continue\r\n\r\n", "").split("\r\n\r\n", 2)
    status, *lines = head.split("\r\n")
    Reply.new(status.split[1].to_i, lines.to_h { |line| line.split(": ", 2).then { |k, v| [k.downcase, v] } }, body, sock.written)
  end
end

# A phone talking to Start with no Listener in front: it reads the head as
# Listener would, and takes Start's answer, or the Http::Error it raised.
class StartPhone < Phone
  def send_raw(text)
    sock = FakeSocket.new(text)
    request = ClaudeInbox::Remote::Http.read_head(sock, deadline: ClaudeInbox::Remote::Http.monotonic + 5)
    status, headers, body, note = @server.call(request, sock, VIA)
    Reply.new(status, headers, body, sock.written, note)
  rescue ClaudeInbox::Remote::Http::Error => e
    Reply.new(e.status, e.headers, JSON.generate(e.body), sock.written, e.note)
  end
end
