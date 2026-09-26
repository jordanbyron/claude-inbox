# frozen_string_literal: true

# The few verbs every spec may use. Each takes what it drives as an argument,
# so none depends on a spec defining a particular let.
module Drivers
  FIXTURES = File.expand_path("../fixtures", __dir__)

  def fixture_path(name) = File.join(FIXTURES, name)

  def session(**attrs)
    ClaudeInbox::Session.new(
      id: "abc12345", cwd: "/tmp/proj", kind: "background",
      started_at: Time.at(1_789_400_000), state: "working", name: "thing", **attrs
    )
  end

  def wait_for(timeout: 2)
    deadline = Time.now + timeout
    sleep 0.01 while !yield && Time.now < deadline
    yield
  end

  # What arrived since the last drain: a Queue's items, or a StringIO's text.
  def drain(source)
    return Array.new(source.size) { source.pop(true) } if source.is_a?(Queue)

    source.string.dup.tap {
      source.truncate(0)
      source.rewind
    }
  end

  def press(app, *keys) = keys.each { |k| app.step(k) }

  # App#step paints before it handles its key, so one more step shows what
  # the last key did.
  def screen(app)
    app.step
    app.instance_variable_get(:@terminal).lines
  end

  def type(input, text) = text.each_char { |c| input.press(c, c) }

  # Sends raw HTTP to a Listener, or to Start the way Listener hands it on,
  # and parses what comes back. A String body goes as is; anything else as JSON.
  def request(server, verb, path, body = nil, token: nil, host: "127.0.0.1:7433", type: "application/json", headers: {})
    body = JSON.generate(body) if body && !body.is_a?(String)
    lines = ["#{verb} #{path} HTTP/1.1"]
    lines << "Host: #{host}" if host
    lines << "Authorization: Bearer #{token}" if token
    lines << "Content-Type: #{type}" if body && type
    lines << "Content-Length: #{body.bytesize}" if body
    headers.each { |name, value| lines << "#{name}: #{value}" }
    request_raw(server, lines.join("\r\n") + "\r\n\r\n" + body.to_s)
  end

  def request_raw(server, text)
    sock = FakeSocket.new(text)
    if server.respond_to?(:handle)
      server.handle(sock, via: "192.168.1.30")
      head, body = sock.written.sub("HTTP/1.1 100 Continue\r\n\r\n", "").split("\r\n\r\n", 2)
      status, *lines = head.split("\r\n")
      headers = lines.to_h { |line| line.split(": ", 2).then { |k, v| [k.downcase, v] } }
      return Reply.new(status.split[1].to_i, headers, body, sock.written)
    end

    request = ClaudeInbox::Remote::Http.read_head(sock, deadline: ClaudeInbox::Remote::Http.monotonic + 5)
    status, headers, body, note = server.call(request, sock, "192.168.1.30")
    Reply.new(status, headers, body, sock.written, note)
  rescue ClaudeInbox::Remote::Http::Error => e
    Reply.new(e.status, e.headers, JSON.generate(e.body), sock.written, e.note)
  end
end

PNG = "\x89PNG\r\n\x1A\n#{"\0" * 16}".b

RSpec.configure { |config| config.include Drivers }
