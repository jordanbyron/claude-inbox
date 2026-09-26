# frozen_string_literal: true

require_relative "../../lib/claude_inbox/remote/listener"
require "tmpdir"

RSpec.describe ClaudeInbox::Remote::Start do
  let(:tmp) { File.realpath(Dir.mktmpdir) }
  let(:project) { mkdir("code", "app") }
  let(:client) { RecordingClient.new }
  let(:store) { ClaudeInbox::Store.new(path: nil).tap { |s| s.update([session(id: "abc12345", cwd: project)]) } }
  let(:queue) { Queue.new }
  let(:trusted) { [] }
  let(:settings) { {} }
  let(:options) { {} }
  let(:remote_start) do
    ClaudeInbox::Remote::Start.new(client: client, store: store, queue: queue,
      allowed_modes: ClaudeInbox::Remote::Listener::DEFAULT_MODES, images_dir: File.join(tmp, "images"),
      jobs_dir: File.join(tmp, "jobs"), trust: -> { trusted },
      settings: ->(dir) { settings.fetch(dir) { ClaudeInbox::Settings::Defaults.new } }, bridge_wait: 0, **options)
  end

  after { FileUtils.remove_entry(tmp) }

  def mkdir(*parts) = File.join(tmp, *parts).tap { |dir| FileUtils.mkdir_p(dir) }

  # Start's answer, or the Http::Error it raised, as Listener would write it.
  def raw(text)
    sock = FakeSocket.new(text)
    request = ClaudeInbox::Remote::Http.read_head(sock, deadline: ClaudeInbox::Remote::Http.monotonic + 5)
    status, headers, body, note = remote_start.call(request, sock, "192.168.1.30")
    Reply.new(status, headers, body, sock.written, note)
  rescue ClaudeInbox::Remote::Http::Error => e
    Reply.new(e.status, e.headers, JSON.generate(e.body), sock.written, e.note)
  end

  def call(verb, path, body = nil, type: "application/json", headers: {})
    body = JSON.generate(body) if body && !body.is_a?(String)
    lines = ["#{verb} #{path} HTTP/1.1"]
    lines << "Content-Type: #{type}" if body && type
    lines << "Content-Length: #{body.bytesize}" if body
    headers.each { |name, value| lines << "#{name}: #{value}" }
    raw(lines.join("\r\n") + "\r\n\r\n" + body.to_s)
  end

  def start(params, **opts) = call("POST", "/api/sessions", params, **opts)

  def drained = Array.new(queue.size) { queue.pop }

  describe "GET /api/options" do
    it "offers the choices, only the permission modes a phone may use, and the directories" do
      older = mkdir("code", "older")
      tree = mkdir("code", "tree", ".claude", "worktrees", "wip")
      store.update([
        session(id: "a", cwd: older, started_at: Time.at(1_000)),
        session(id: "b", cwd: tree, started_at: Time.at(3_000)),
        session(id: "c", cwd: project, started_at: Time.at(2_000))
      ])
      trusted.replace([mkdir("code", "trusted"), project, File.join(tmp, "gone")])
      settings[project] = ClaudeInbox::Settings::Defaults.new("opus", nil, "plan")
      body = call("GET", "/api/options").json
      expect(body["models"]).to eq(ClaudeInbox::AgentsClient::MODELS)
      expect(body["efforts"]).to eq(ClaudeInbox::AgentsClient::EFFORTS)
      expect(body["permission_modes"]).to eq(%w[default auto plan])
      expect(body["dirs"].map { |d| d["label"] }).to eq(%w[tree app older trusted])
      expect(body["dirs"][1]).to eq({"path" => project, "label" => "app", "defaults" => {"model" => "opus", "effort" => nil, "permission_mode" => "plan", "remote" => nil}})
      expect(body).not_to include("fixture")
    end

    it "labels a directory by as many trailing names as it takes to tell it apart" do
      trusted.replace([mkdir("a", "x", "app"), mkdir("b", "x", "app")])
      expect(call("GET", "/api/options").json["dirs"].map { |d| d["label"] }).to eq(%w[code/app a/x/app b/x/app])
    end

    it "says when it is a fixture, so a test inbox can't pass for a real one" do
      options[:fixture] = true
      expect(call("GET", "/api/options").json["fixture"]).to be(true)
    end
  end

  describe "POST /api/sessions" do
    it "starts the session the form would, and tells the inbox without moving anything" do
      r = start({prompt: "fix it", cwd: "app", name: "phone", model: "opus", remote: true})
      expect(r.status).to eq(201)
      expect(r.json).to eq({"id" => "deadbeef", "name" => "phone", "cwd" => project, "url" => nil})
      expect(client.spawns).to eq([{prompt: "fix it", name: "phone", cwd: project, model: "opus", effort: nil,
                                    permission_mode: "auto", worktree: false, remote: true}])
      expect(drained).to eq([[:notice, "remote: starting session…"], [:remote_started, "deadbeef", "192.168.1.30"]])
      expect(r.note).to eq("started deadbeef")
    end

    it "hands back the claude.ai/code page once the session has registered its bridge" do
      FileUtils.mkdir_p(File.join(tmp, "jobs", "deadbeef"))
      File.write(File.join(tmp, "jobs", "deadbeef", "state.json"), JSON.generate(bridgeSessionId: "cse_01AbC"))
      expect(start({prompt: "go", cwd: project, remote: true}).json["url"]).to eq("https://claude.ai/code/session_01AbC")
    end

    it "answers without waiting for a bridge a session without Remote Control seldom registers" do
      options[:bridge_wait] = 3
      began = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      r = start({prompt: "go", cwd: project, remote: false})
      expect(r.status).to eq(201)
      expect(r.json["url"]).to be_nil
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - began).to be < 1
    end

    it "still hands back a bridge that is already there without Remote Control, looking once" do
      FileUtils.mkdir_p(File.join(tmp, "jobs", "deadbeef"))
      File.write(File.join(tmp, "jobs", "deadbeef", "state.json"), JSON.generate(bridgeSessionId: "cse_01AbC"))
      options[:bridge_wait] = 3
      began = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(start({prompt: "go", cwd: project, remote: false}).json["url"]).to eq("https://claude.ai/code/session_01AbC")
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - began).to be < 1
    end

    it "refuses what the form refuses, naming the field, and starts nothing" do
      {
        {prompt: "go", cwd: project, permissions: "plan"} => ["permissions", "unknown key: \"permissions\""],
        {prompt: "  ", cwd: project} => ["prompt", "a prompt is required"],
        {prompt: "go", cwd: "/no/such/dir"} => ["cwd", "no such directory: /no/such/dir"],
        {prompt: "go", cwd: "nowhere"} => ["cwd", "no directory called nowhere"],
        {prompt: "go", cwd: project, model: "gpt"} => ["model", "model is one of default, fable, opus, sonnet, haiku"]
      }.each do |params, (field, message)|
        r = start(params)
        expect([r.status, r.json]).to eq([422, {"error" => message, "field" => field}])
      end
      expect(client.spawns).to be_empty
      expect(drained).to be_empty
    end

    it "caps the permission mode after working out what default means in that directory" do
      expect(start({prompt: "go", cwd: project, permission_mode: "bypassPermissions"}).json).to eq(
        {"error" => "permission mode bypassPermissions isn't allowed from another device", "field" => "permission_mode"}
      )
      settings[project] = ClaudeInbox::Settings::Defaults.new(nil, nil, "acceptEdits")
      expect(start({prompt: "go", cwd: project}).status).to eq(403)
      settings[project] = ClaudeInbox::Settings::Defaults.new(nil, nil, "plan")
      expect(start({prompt: "go", cwd: project}).status).to eq(201)
      expect(client.spawns.map { |s| s[:permission_mode] }).to eq(%w[plan])
    end

    it "follows /config's Remote Control setting when the request leaves remote out, as the form does" do
      settings[project] = ClaudeInbox::Settings::Defaults.new(remote: "yes")
      start({prompt: "go", cwd: project})
      start({prompt: "go", cwd: project, remote: false})
      settings[project] = ClaudeInbox::Settings::Defaults.new(remote: "no")
      start({prompt: "go", cwd: project})
      expect(client.spawns.map { |s| s[:remote] }).to eq([true, false, false])
    end

    it "names the mode it let through, so the CLI doesn't work default out again for itself" do
      settings[project] = ClaudeInbox::Settings::Defaults.new(nil, nil, "plan")
      start({prompt: "go", cwd: project})
      argv = ClaudeInbox::AgentsClient.spawn_args("claude", **client.spawns.last.except(:cwd))
      expect(argv.each_cons(2).to_a).to include(["--permission-mode", "plan"])
    end

    it "names auto where settings name no mode, so a settings file it doesn't read can't widen it" do
      expect(start({prompt: "go", cwd: project}).status).to eq(201)
      argv = ClaudeInbox::AgentsClient.spawn_args("claude", **client.spawns.last.except(:cwd))
      expect(argv.each_cons(2).to_a).to include(["--permission-mode", "auto"])
    end

    it "names default there instead when auto isn't allowed, rather than let the CLI pick auto" do
      options[:allowed_modes] = %w[default plan]
      expect(start({prompt: "go", cwd: project}).status).to eq(201)
      argv = ClaudeInbox::AgentsClient.spawn_args("claude", **client.spawns.last.except(:cwd))
      expect(argv.each_cons(2).to_a).to include(["--permission-mode", "default"])
    end

    it "takes the wider list it was given" do
      options[:allowed_modes] = %w[default plan acceptEdits]
      expect(start({prompt: "go", cwd: project, permission_mode: "acceptEdits"}).status).to eq(201)
      expect(call("GET", "/api/options").json["permission_modes"]).to eq(%w[default acceptEdits plan])
    end

    it "wants a JSON object, sized up front" do
      expect(start({prompt: "go"}, type: "text/plain").status).to eq(415)
      expect(start({prompt: "go"}, type: "application/json; charset=utf-8").status).to eq(422)
      expect(start("[1]").status).to eq(400)
      expect(start("{").status).to eq(400)
      expect(start("{\"prompt\": \"\xFF\"}".b).json["error"]).to eq("the body isn't UTF-8")
      expect(raw("POST /api/sessions HTTP/1.1\r\nContent-Type: application/json\r\n\r\n").status).to eq(411)
      expect(start("{}", headers: {"Transfer-Encoding" => "chunked"}).status).to eq(400)
      too_big = raw("POST /api/sessions HTTP/1.1\r\n" \
        "Content-Type: application/json\r\nContent-Length: #{16 * 1024 * 1024 + 1}\r\n\r\n")
      expect(too_big.status).to eq(413)
    end

    it "saves the images only once the request passes, and points the prompt at them" do
      data = [PNG].pack("m0")
      expect(start({prompt: "", cwd: project, images: [{data: data}]}).status).to eq(422)
      expect(Dir.exist?(File.join(tmp, "images"))).to be(false)

      expect(start({prompt: "like [Image #2], not [Image #1]", cwd: project, images: [{data: data}, {data: data}]}).status).to eq(201)
      saved = Dir.glob(File.join(tmp, "images", "*.png")).sort
      expect(saved.size).to eq(2)
      expect(saved.map { |f| File.stat(f).mode & 0o777 }.uniq).to eq([0o600])
      expect(client.spawns.last[:prompt]).to eq("like @#{saved[1]}, not @#{saved[0]}")
    end

    it "refuses more than eight images, or one that isn't an image, saying which" do
      png = {data: [PNG].pack("m0")}
      expect(start({prompt: "go", cwd: project, images: [png] * 9}).status).to eq(413)
      r = start({prompt: "go", cwd: project, images: [png, {data: ["hello"].pack("m0")}]})
      expect([r.status, r.json]).to eq([415, {"error" => "image 2 isn't a PNG, JPEG, GIF or WebP image", "field" => "images", "index" => 1}])
      expect(start({prompt: "go", cwd: project, images: [{data: "!!not base64"}]}).json["index"]).to eq(0)
      expect(start({prompt: "go", cwd: project, images: ["x"]}).status).to eq(415)
      expect(start({prompt: "go", cwd: project, images: "x"}).status).to eq(422)
      expect(client.spawns).to be_empty
    end

    it "answers a repeated Idempotency-Key with the first answer instead of a second session" do
      first = start({prompt: "go", cwd: project}, headers: {"Idempotency-Key" => "k1"})
      again = start({prompt: "go", cwd: project}, headers: {"Idempotency-Key" => "k1"})
      expect([first.status, again.status]).to eq([201, 200])
      expect(again.json).to eq(first.json)
      expect(client.spawns.size).to eq(1)
      expect(start({prompt: "go", cwd: project}, headers: {"Idempotency-Key" => "k2"}).status).to eq(201)
    end

    it "refuses a key sent again with a different request, rather than answer it with the first start" do
      expect(start({prompt: "first task", cwd: project}, headers: {"Idempotency-Key" => "k1"}).status).to eq(201)
      r = start({prompt: "second task", cwd: project}, headers: {"Idempotency-Key" => "k1"})
      expect([r.status, r.json]).to eq([422, {"error" => "this Idempotency-Key was sent with a different request"}])
      expect(client.spawns.map { |s| s[:prompt] }).to eq(["first task"])
      expect(start({prompt: "first task", cwd: project}, headers: {"Idempotency-Key" => "k1"}).status).to eq(200)
    end

    it "takes an empty Idempotency-Key as none, so every start is a new one" do
      2.times { expect(start({prompt: "go", cwd: project}, headers: {"Idempotency-Key" => ""}).status).to eq(201) }
      expect(client.spawns.size).to eq(2)
    end

    it "says 409 while the first request with that key is still starting" do
      client.hold
      first = Thread.new { start({prompt: "go", cwd: project}, headers: {"Idempotency-Key" => "k1"}) }
      expect(wait_for { client.spawns.size == 1 }).to be(true)
      expect(start({prompt: "go", cwd: project}, headers: {"Idempotency-Key" => "k1"}).json).to eq({"error" => "already starting"})
      client.release
      expect(first.value.status).to eq(201)
    end

    it "passes the CLI's refusal on as a 500, and lets the same key try again" do
      client.fail_spawn("claude --bg failed: Workspace not trusted")
      r = start({prompt: "go", cwd: project}, headers: {"Idempotency-Key" => "k1"})
      expect([r.status, r.json]).to eq([500, {"error" => "claude --bg failed: Workspace not trusted", "source" => "claude"}])
      expect(drained.last).to eq([:notice, "remote start failed: claude --bg failed: Workspace not trusted"])
      expect(r.note).to eq("claude --bg failed: Workspace not trusted")
      client.fail_spawn(nil)
      expect(start({prompt: "go", cwd: project}, headers: {"Idempotency-Key" => "k1"}).status).to eq(201)
    end

    it "says so under --fixture, on the answer as well" do
      options[:fixture] = true
      expect(start({prompt: "go", cwd: project}).json["fixture"]).to be(true)
    end
  end
end
