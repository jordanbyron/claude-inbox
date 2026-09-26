# frozen_string_literal: true

require "net/http"
require "tmpdir"

RSpec.describe ClaudeInbox::Remote::Listener do
  let(:tmp) { File.realpath(Dir.mktmpdir) }
  let(:project) { File.join(tmp, "code", "app").tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:client) { RecordingClient.new }
  let(:store) { ClaudeInbox::Store.new(path: nil).tap { |s| s.update([session(id: "abc12345", cwd: project)]) } }
  let(:queue) { Queue.new }
  let(:trusted) { [] }
  let(:settings) { {} }
  let(:options) { {} }
  let(:pairing) do
    ClaudeInbox::Remote::Pairing.new(path: File.join(tmp, "listen.json"), local_name: -> { "mac-mini" },
      hostname: -> { "mac-mini" }, addresses: -> { [Addrinfo.ip("192.168.1.20")] }, firewall: -> { :off })
  end
  let(:token) { pairing.token }
  let(:listener_args) do
    {client: client, store: store, queue: queue, pairing: pairing, port: 7433,
     images_dir: File.join(tmp, "images"), jobs_dir: File.join(tmp, "jobs"), lock_path: File.join(tmp, "listen.lock"),
     trust: -> { trusted }, settings: ->(dir) { settings.fetch(dir) { ClaudeInbox::Settings::Defaults.new } },
     bridge_wait: 0, **options}
  end
  let(:listener) { described_class.new(**listener_args) }

  after do
    listener.stop
    FileUtils.remove_entry(tmp)
  end

  describe "routing and the token" do
    it "serves the phone page at / to anyone, as HTML that reaches only this listener and can't be framed" do
      r = request(listener, "GET", "/", token: nil)
      expect(r.status).to eq(200)
      expect(r.headers["content-type"]).to eq("text/html; charset=utf-8")
      expect(r.headers["content-security-policy"]).to eq("default-src 'none'; script-src 'unsafe-inline'; " \
        "style-src 'unsafe-inline'; img-src blob: data:; connect-src 'self'; manifest-src 'self'; form-action 'none'; " \
        "frame-ancestors 'none'")
      expect(r.body.b).to eq(File.binread(File.expand_path("../../lib/claude_inbox/remote/page.html", __dir__)))
      expect(r.headers.values_at("connection", "cache-control", "x-content-type-options", "referrer-policy"))
        .to eq(["close", "no-store", "nosniff", "no-referrer"])
    end

    it "serves what Add to Home Screen reads to anyone, so the page opens as an app with its own icon" do
      manifest = request(listener, "GET", "/manifest.webmanifest", token: nil)
      expect([manifest.status, manifest.headers["content-type"]]).to eq([200, "application/manifest+json"])
      expect(manifest.json.values_at("start_url", "display")).to eq(["/", "standalone"])
      expect(manifest.json["icons"].map { |icon| icon["src"] }).to eq(["/icon.png"])
      icon = request(listener, "GET", "/icon.png", token: nil)
      expect([icon.status, icon.headers["content-type"]]).to eq([200, "image/png"])
      expect(icon.body.b).to eq(File.binread(File.expand_path("../../lib/claude_inbox/remote/icon.png", __dir__)))
    end

    it "asks for the token, says how to get one, and notes who was turned away" do
      [nil, "wrong", pairing.token + "x"].each do |token|
        r = request(listener, "GET", "/api/options", token: token)
        expect(r.status).to eq(401)
        expect(r.headers["www-authenticate"]).to eq("Bearer")
        expect(r.json["error"]).to include("press N")
      end
      expect(listener.snapshot.recent.map { |o| [o.via, o.result, o.count] }).to eq([["192.168.1.30", "token rejected", 3]])
    end

    it "counts rejected tokens from one place in one entry, so they can't push the starts out of N" do
      request(listener, "POST", "/api/sessions", {prompt: "go", cwd: project}, token: token)
      20.times { request(listener, "GET", "/api/options", token: "wrong") }
      expect(listener.snapshot.recent.map { |o| [o.result, o.count] }).to eq([["started deadbeef", 1], ["token rejected", 20]])
    end

    it "turns a request without the token away before reading its body or inviting it" do
      r = request_raw(listener, "POST /api/sessions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer wrong\r\n" \
        "Content-Type: application/json\r\nContent-Length: 999999999\r\nExpect: 100-continue\r\n\r\n")
      expect(r.status).to eq(401)
      expect(r.written).not_to include("100 Continue")
      expect(client.spawns).to be_empty
    end

    it "answers only to the names it was reached by, so a rebound DNS name gets nowhere" do
      expect(request(listener, "GET", "/api/options", host: "evil.example:7433", token: token).status).to eq(421)
      expect(request(listener, "GET", "/api/options", host: "192.168.1.20:7433", token: token).status).to eq(421)
      expect(request(listener, "GET", "/", token: nil, host: nil).status).to eq(421)
      expect(request(listener, "GET", "/api/options", host: "LOCALHOST:7433", token: token).status).to eq(200)
      expect(request(listener, "GET", "/api/options", host: "127.0.0.1", token: token).status).to eq(200)
      expect(request(listener, "GET", "/api/options", host: "[::1]:7433", token: token).status).to eq(200)
    end

    it "takes any port with the name, as an ssh tunnel on another local port sends it" do
      expect(request(listener, "GET", "/api/options", host: "localhost:8000", token: token).status).to eq(200)
      expect(request(listener, "GET", "/api/options", host: "evil.example:8000", token: token).status).to eq(421)
    end

    it "answers to this Mac's names and addresses in LAN mode" do
      lan = described_class.new(**listener_args, lan: true)
      [["mac-mini.local:7433", 200], ["192.168.1.20:7433", 200], ["evil.example", 421]].each do |host, status|
        sock = FakeSocket.new("GET / HTTP/1.1\r\nHost: #{host}\r\n\r\n")
        lan.handle(sock, via: "192.168.1.30")
        expect(sock.written).to match(/\AHTTP\/1\.1 #{status} /)
      end
    end

    it "takes GET and POST only, each on its own path, and knows no other path" do
      put = request(listener, "PUT", "/api/sessions", "{}", token: token)
      expect([put.status, put.headers["allow"]]).to eq([405, "GET, POST"])
      expect(request(listener, "OPTIONS", "/api/sessions", token: nil).status).to eq(405)
      get = request(listener, "GET", "/api/sessions", token: token)
      expect([get.status, get.headers["allow"]]).to eq([405, "POST"])
      expect(request(listener, "POST", "/api/options", "{}", token: token).headers["allow"]).to eq("GET")
      expect(request(listener, "GET", "/api/nope", token: token).status).to eq(404)
      expect(request_raw(listener, "garbage\r\n\r\n").status).to eq(400)
    end
  end

  describe "the phone page" do
    let(:page) { described_class::PAGE }

    it "refuses what the listener would, before sending it" do
      expect(page).to include("const MAX_IMAGES = #{ClaudeInbox::Remote::Start::MAX_IMAGES};")
      expect(page).to include("const MAX_BODY = #{ClaudeInbox::Remote::Start::MAX_BODY};")
    end

    it "loads nothing from anywhere else, which the CSP would block without a word" do
      expect(page).not_to include("@import")
      expect(page.scan(/<link\b[^>]*>/).map { |link| link[/href="([^"]*)"/, 1] }).to eq(["/manifest.webmanifest", "/icon.png"])
      expect(page).not_to match(%r{\b(?:src|href|action)=["']?(?:https?:)?//})
      expect(page).not_to match(%r{url\(["']?(?:https?:)?//})
    end

    it "sends only the keys a start takes, so none is refused as unknown" do
      fields = page[/const fields = \{(.*?)\};/m, 1].scan(/(\w+):/).flatten
      expect(page).to match(/const body = JSON\.stringify\(\{\.\.\.fields, images: /)
      expect((fields + %w[images]).sort).to eq((ClaudeInbox::SessionRequest::KEYS + %w[images]).sort)
    end
  end

  describe "handing a request to Start" do
    it "starts a session once the token checks out, and lists it for N" do
      r = request(listener, "POST", "/api/sessions", {prompt: "fix it", cwd: project}, token: token)
      expect(r.status).to eq(201)
      expect(client.spawns.size).to eq(1)
      expect(listener.snapshot.recent.last.result).to eq("started deadbeef")
    end

    it "lets nothing a request sent reach the terminal as an escape sequence" do
      expect(request(listener, "POST", "/api/sessions", {prompt: "x", cwd: "/tmp/\e]0;PWNED\a\e[2J"}, token: token).status).to eq(422)
      expect(request(listener, "POST", "/api/sessions", {"\e[31mkey" => 1}, token: token).status).to eq(422)
      client.fail_spawn("claude --bg failed: \e[2Jno such directory")
      request(listener, "POST", "/api/sessions", {prompt: "go", cwd: project}, token: token)
      results = listener.snapshot.recent.map(&:result)
      expect(results.size).to eq(3)
      expect(results.join).not_to include("\e")
      expect(results.last).to eq("claude --bg failed: \\x1b[2Jno such directory")
      expect(drain(queue).last).to eq([:notice, "remote start failed: claude --bg failed: \\x1b[2Jno such directory"])
    end

    it "notes a refused start for N, as it does a failed one" do
      request(listener, "POST", "/api/sessions", {prompt: "go", cwd: project, permission_mode: "bypassPermissions"}, token: token)
      expect(listener.snapshot.recent.last.result).to eq("refused: permission mode bypassPermissions isn't allowed from another device")
    end

    it "answers anything else that goes wrong with a 500 and its message" do
      options[:images_dir] = File.join(tmp, "listen.json").tap { |f| File.write(f, "") }
      r = request(listener, "POST", "/api/sessions", {prompt: "go", cwd: project, images: [{data: [PNG].pack("m0")}]}, token: token)
      expect(r.status).to eq(500)
      expect(r.json["error"]).to include("File exists")
    end

    it "keeps what went wrong to itself until the token checks out" do
      FileUtils.mkdir_p(File.join(tmp, "listen.json"))
      r = request(listener, "GET", "/api/options", token: "a-guess")
      expect([r.status, r.json]).to eq([500, {"error" => "internal error"}])
    end
  end

  describe "over a socket" do
    let(:options) { {port: 0} }

    it "binds a port of its own, answers over HTTP, and lets go of it on stop" do
      listener.start
      expect(listener.snapshot.state).to eq(:listening)
      port = listener.port
      expect(port).to be > 0
      Net::HTTP.start("127.0.0.1", port) do |http|
        auth = {"Authorization" => "Bearer #{pairing.token}"}
        expect(http.get("/api/options", auth).code).to eq("200")
        posted = http.post("/api/sessions", JSON.generate(prompt: "go", cwd: "app"), auth.merge("Content-Type" => "application/json"))
        expect([posted.code, JSON.parse(posted.body)["id"]]).to eq(["201", "deadbeef"])
      end
      expect(drain(queue).last).to eq([:remote_started, "deadbeef", "127.0.0.1"])
      listener.stop
      expect(listener.snapshot.state).to eq(:off)
      expect { TCPSocket.new("127.0.0.1", port) }.to raise_error(Errno::ECONNREFUSED)
      again = described_class.new(**listener_args, port: port)
      again.start
      expect(again.snapshot.state).to eq(:listening)
    ensure
      again&.stop
    end

    it "leaves a second inbox saying who is listening, and lets it take over once that one quits" do
      listener.start
      second = described_class.new(**listener_args, retry_every: 0.05)
      second.start
      expect([second.snapshot.state, second.snapshot.held_by]).to eq([:held, Process.pid])
      listener.stop
      expect(wait_for { second.snapshot.state == :listening }).to be(true)
      expect(second.snapshot.held_by).to be_nil
    ensure
      second&.stop
    end

    it "says the port is in use rather than sharing it, and gives the lock back" do
      taken = Socket.new(:INET, :STREAM)
      taken.bind(Addrinfo.tcp("127.0.0.1", 0))
      taken.listen(1)
      busy = described_class.new(**listener_args, port: taken.local_address.ip_port)
      busy.start
      expect(busy.snapshot.state).to eq(:in_use)
      listener.start
      expect(listener.snapshot.state).to eq(:listening)
    ensure
      busy&.stop
      taken.close
    end

    it "fills in the pairing URLs asked for while it waited, once it binds" do
      taken = Socket.new(:INET, :STREAM)
      taken.bind(Addrinfo.tcp("127.0.0.1", 0))
      taken.listen(1)
      busy = described_class.new(**listener_args, port: taken.local_address.ip_port, retry_every: 0.05)
      busy.start
      busy.refresh
      expect(busy.snapshot.urls).to be_nil
      taken.close
      expect(wait_for { busy.snapshot.urls }).to eq(["http://127.0.0.1:#{busy.port}/##{pairing.token}"])
    ensure
      busy&.stop
      taken.close unless taken.closed?
    end

    it "says what went wrong, and stops trying, when it can't even take the lock" do
      locked = File.join(tmp, "locked").tap { |dir| FileUtils.mkdir_p(dir) }
      File.chmod(0o500, locked)
      broken = described_class.new(**listener_args, lock_path: File.join(locked, "sub", "listen.lock"), retry_every: 0.05)
      broken.start
      s = broken.snapshot
      expect(s.state).to eq(:failed)
      expect(s.error).to include("Permission denied")
      File.chmod(0o700, locked)
      sleep 0.2
      expect(broken.snapshot.state).to eq(:failed)
    ensure
      broken&.stop
      File.chmod(0o700, locked) if locked
    end

    it "binds once the port is free again" do
      taken = Socket.new(:INET, :STREAM)
      taken.bind(Addrinfo.tcp("127.0.0.1", 0))
      taken.listen(1)
      busy = described_class.new(**listener_args, port: taken.local_address.ip_port, retry_every: 0.05)
      busy.start
      expect(busy.snapshot.state).to eq(:in_use)
      taken.close
      expect(wait_for { busy.snapshot.state == :listening }).to be(true)
    ensure
      busy&.stop
      taken.close unless taken.closed?
    end

    # A client sends its whole request before it reads the answer, as
    # Net::HTTP and a browser do. Closing on that upload unread resets it,
    # and the client never gets as far as reading the 503.
    it "turns a third connection away while two have yet to show a token, and lets it hear why" do
      listener.start
      idle = Array.new(2) { TCPSocket.new("127.0.0.1", listener.port) }
      third = TCPSocket.new("127.0.0.1", listener.port)
      upload = Thread.new do
        third.write("POST /api/sessions HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 2000000\r\n\r\n" + "x" * 2_000_000)
        :sent
      rescue SystemCallError => e
        e.class
      end
      expect(upload.value).to eq(:sent)
      answer = third.readpartial(4096)
      expect(answer).to match(/\AHTTP\/1\.1 503 /)
      expect(answer).to include("Retry-After: 2")
    ensure
      [*idle, third].compact.each(&:close)
    end

    # Every test connection comes from 127.0.0.1, so `peer` names the host.
    it "lets another host in while one holds its two unauthenticated slots" do
      hosts = Queue.new
      allow(listener).to receive(:peer) { hosts.pop }
      listener.start
      idle = Array.new(2) do
        hosts << "192.168.1.30"
        TCPSocket.new("127.0.0.1", listener.port)
      end
      get = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
      statuses = %w[192.168.1.30 192.168.1.31].map do |host|
        hosts << host
        TCPSocket.open("127.0.0.1", listener.port) { |sock| sock.write(get) && sock.readpartial(4096)[/\AHTTP\/1\.1 (\d+)/, 1] }
      end
      expect(statuses).to eq(%w[503 200])
    ensure
      idle&.each(&:close)
    end

    it "stops counting a connection as unauthenticated once its token checks out" do
      listener.start
      held = TCPSocket.new("127.0.0.1", listener.port)
      held.write("POST /api/sessions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer #{pairing.token}\r\n" \
        "Content-Type: application/json\r\nContent-Length: 10\r\nExpect: 100-continue\r\n\r\n")
      expect(held.readpartial(4096)).to include("100 Continue")
      idle = TCPSocket.new("127.0.0.1", listener.port)
      expect(Net::HTTP.get_response(URI("http://127.0.0.1:#{listener.port}/")).code).to eq("200")
    ensure
      [held, idle].compact.each(&:close)
    end

    it "gives each connection's slot back once it is answered" do
      listener.start
      statuses = Array.new(6) { Net::HTTP.get_response(URI("http://127.0.0.1:#{listener.port}/api/options")).code }
      expect(statuses.uniq).to eq(["401"])
    end

    it "publishes the pairing URLs once refreshed, and new ones after a rotate" do
      listener.start
      expect(listener.snapshot.urls).to be_nil
      listener.refresh
      first = listener.snapshot.urls
      expect(first).to eq(["http://127.0.0.1:#{listener.port}/##{pairing.token}"])
      expect(listener.snapshot.pairing_url).to eq(first.first)
      listener.rotate.join
      expect(listener.snapshot.urls).not_to eq(first)
    end
  end

  it "keeps the last five outcomes" do
    (1..6).each do |n|
      listener.handle(FakeSocket.new("GET /api/options HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"), via: "192.168.1.#{n}")
    end
    expect(listener.snapshot.recent.map(&:via)).to eq((2..6).map { |n| "192.168.1.#{n}" })
  end

  it "stays off, and says so, when disabled" do
    off = described_class.disabled
    off.start
    off.refresh
    off.stop
    expect(off.snapshot.state).to eq(:off)
    expect(off.port).to be_nil
  end

  describe ".options" do
    it "is nil unless a flag or the environment asks for the listener" do
      expect(described_class.options(["--fixture", "x.json"], {})).to be_nil
      expect(described_class.options(["--listen-allow-modes=plan"], {})).to be_nil
      expect(described_class.options([], {"CLAUDE_INBOX_LISTEN" => " "})).to be_nil
    end

    it "listens on loopback at 7433 for phone-safe modes unless told otherwise" do
      expect(described_class.options(["--listen"], {})).to eq({port: 7433, lan: false, allowed_modes: %w[default auto plan]})
      expect(described_class.options(["--listen=8080"], {})[:port]).to eq(8080)
      expect(described_class.options(["--listen-lan"], {})).to eq({port: 7433, lan: true, allowed_modes: %w[default auto plan]})
      expect(described_class.options(["--listen-lan=9000"], {})[:port]).to eq(9000)
      expect(described_class.options(["--listen=0"], {})[:port]).to eq(0)
    end

    it "widens to the LAN only when --listen-lan says so, whatever order the flags came in" do
      expect(described_class.options(["--listen-lan", "--listen=8080"], {})).to eq({port: 7433, lan: true, allowed_modes: %w[default auto plan]})
      expect(described_class.options(["--listen=8080", "--listen-lan=9000"], {})[:lan]).to be(true)
    end

    it "reads the environment when no flag is given, and a flag over it" do
      expect(described_class.options([], {"CLAUDE_INBOX_LISTEN" => "7500"})).to eq({port: 7500, lan: false, allowed_modes: %w[default auto plan]})
      expect(described_class.options([], {"CLAUDE_INBOX_LISTEN" => "lan"})).to eq({port: 7433, lan: true, allowed_modes: %w[default auto plan]})
      expect(described_class.options([], {"CLAUDE_INBOX_LISTEN" => "lan:7500"})).to eq({port: 7500, lan: true, allowed_modes: %w[default auto plan]})
      expect(described_class.options(["--listen"], {"CLAUDE_INBOX_LISTEN" => "lan"})[:lan]).to be(false)
      expect(described_class.options([], {"CLAUDE_INBOX_LISTEN" => "lan", "CLAUDE_INBOX_LISTEN_ALLOW_MODES" => "plan"})[:allowed_modes]).to eq(%w[plan])
      expect(described_class.options(["--listen", "--listen-allow-modes=default, acceptEdits"], {})[:allowed_modes]).to eq(%w[default acceptEdits])
    end

    it "refuses a port or a mode it can't use" do
      expect { described_class.options(["--listen=http"], {}) }.to raise_error(ArgumentError)
      expect { described_class.options(["--listen=70000"], {}) }.to raise_error(ArgumentError)
      expect { described_class.options(["--listen="], {}) }.to raise_error(ArgumentError)
      expect { described_class.options([], {"CLAUDE_INBOX_LISTEN" => "yes"}) }.to raise_error(ArgumentError)
      expect { described_class.options(["--listen", "--listen-allow-modes=plan,yolo"], {}) }.to raise_error(ArgumentError) { |error|
        expect(error.message).to include("yolo")
      }
    end
  end
end
