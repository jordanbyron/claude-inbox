# frozen_string_literal: true

# Requests for the Remote specs, which send them through Listener or
# straight to Start. Calls the group's `tmp` and `queue`; `raw` comes from
# RemoteListenerHelpers or RemoteStartHelpers.
module RemoteHelpers
  def mkdir(*parts) = File.join(tmp, *parts).tap { |dir| FileUtils.mkdir_p(dir) }

  def call(verb, path, body = nil, head: [], type: "application/json", headers: {})
    body = JSON.generate(body) if body && !body.is_a?(String)
    lines = ["#{verb} #{path} HTTP/1.1", *head]
    lines << "Content-Type: #{type}" if body && type
    lines << "Content-Length: #{body.bytesize}" if body
    headers.each { |name, value| lines << "#{name}: #{value}" }
    raw(lines.join("\r\n") + "\r\n\r\n" + body.to_s)
  end

  def start(params, **opts) = call("POST", "/api/sessions", params, **opts)

  def drained = Array.new(queue.size) { queue.pop }
end

# Requests through Listener#handle, carrying a Host and the token unless
# told otherwise. Calls the group's `listener`, `pairing`, `client`, `store`,
# `trusted`, `settings` and `options`.
module RemoteListenerHelpers
  include RemoteHelpers

  def listener_with(**overrides)
    ClaudeInbox::Remote::Listener.new(client: client, store: store, queue: queue, pairing: pairing, port: 7433,
      images_dir: File.join(tmp, "images"), jobs_dir: File.join(tmp, "jobs"), lock_path: File.join(tmp, "listen.lock"),
      trust: -> { trusted }, settings: ->(dir) { settings.fetch(dir) { ClaudeInbox::Settings::Defaults.new } },
      bridge_wait: 0, **options, **overrides)
  end

  def options_for(*argv, **env) = ClaudeInbox::Remote::Listener.options(argv, env.transform_keys(&:to_s))

  def call(verb, path, body = nil, token: pairing.token, host: "127.0.0.1:7433", **opts)
    head = ["Host: #{host}"]
    head << "Authorization: Bearer #{token}" if token
    super(verb, path, body, head: head, **opts)
  end

  def raw(text)
    sock = FakeSocket.new(text)
    listener.handle(sock, via: "192.168.1.30")
    head, body = sock.written.sub("HTTP/1.1 100 Continue\r\n\r\n", "").split("\r\n\r\n", 2)
    status, *lines = head.split("\r\n")
    Reply.new(status.split[1].to_i, lines.to_h { |line| line.split(": ", 2).then { |k, v| [k.downcase, v] } }, body, sock.written)
  end
end

# Requests handed straight to Start, with no Host or token. Calls the
# group's `remote_start`.
module RemoteStartHelpers
  include RemoteHelpers

  # Start's answer, or the Http::Error it raised, as Listener would write it.
  def raw(text)
    sock = FakeSocket.new(text)
    request = ClaudeInbox::Remote::Http.read_head(sock, deadline: ClaudeInbox::Remote::Http.monotonic + 5)
    status, headers, body, note = remote_start.call(request, sock, "192.168.1.30")
    Reply.new(status, headers, body, sock.written, note)
  rescue ClaudeInbox::Remote::Http::Error => e
    Reply.new(e.status, e.headers, JSON.generate(e.body), sock.written, e.note)
  end
end

RSpec.configure do |config|
  config.include RemoteListenerHelpers, :remote_listener
  config.include RemoteStartHelpers, :remote_start
end
