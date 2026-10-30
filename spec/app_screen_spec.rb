# frozen_string_literal: true

require "stringio"
require "tmpdir"

RSpec.describe ClaudeInbox::App do
  let(:ctrl_x) { "\x18" }

  let(:terminal) { ScreenTerminal.new }

  let(:client) { RecordingClient.new }
  let(:store) { ClaudeInbox::Store.new(path: nil) }
  let(:pull_requests) { ClaudeInbox::PullRequests.new(cache_path: nil, resolved_path: nil, gh: nil) }
  let(:queue) { Queue.new }
  let(:trusted) { [] }

  let(:app) { build_app(client:, store:, pull_requests:, queue:, terminal:, trust: -> { trusted }) }

  after { client.release }

  it "draws in color, and without any under --no-color" do
    painted = []
    allow(terminal).to receive(:paint).and_wrap_original { |paint, lines| painted << lines.join and paint.call(lines) }
    build_app(client:, store:, pull_requests:, queue:, terminal:, color: true)
    build_app(client:, store:, pull_requests:, queue:, terminal:, color: false)
    expect(painted.first).to include("\e[")
    expect(painted.last).not_to include("\e[")
  end

  it "reads the same in color as without, on every screen and in every modal" do
    allow(Time).to receive(:now).and_return(Time.at(1_789_604_500))
    prs = [ClaudeInbox::PullRequest.new(number: 190, url: "https://github.com/o/r/pull/190", state: "OPEN", health: "FAILING",
      title: "Install the pane from the CLI so a first run never has to ask for it twice or more"),
      ClaudeInbox::PullRequest.new(number: 191, url: "https://github.com/o/r/pull/191", state: "MERGED")]
    apps = [true, false].map do |color|
      own = ClaudeInbox::Store.new(path: nil)
      app = build_app(client:, store: own, pull_requests:, queue: Queue.new, terminal: ScreenTerminal.new, color:,
        clipboard: ->(_) { true })
      own.update(own.sessions.map { |s| (s.id == "f23c8673") ? s.with(prs: prs) : s })
      app
    end
    ["o", "\e", "y", "\e", "s", "\e", "a", "\e", "X", "\e", "n", "\e", "N", "\e", "/", "x", "\e", "G", "za"].each do |key|
      colored, plain = apps.map { |app| press(app, key) && screen(app) }
      expect(colored).to eq(plain), "after #{key.inspect}"
      expect(plain.join).to include("Open pull request") if key == "o"
    end
  end

  it "says a refresh is coming from R until the poll lands" do
    queue << [:sessions]
    app.step
    expect(app).not_to paint("refreshing…").in_status_line
    press(app, "R")
    expect(app).to paint("refreshing…").in_status_line
    queue << [:sessions]
    expect(app).not_to paint("refreshing…").in_status_line
  end

  it "hands a paste to the new-session form whole, and types it into the filter" do
    press(app, "/", "\e[200~thi\e[201~")
    expect(app).to paint("/thi").in_footer
    press(app, "\e", "n", "\e[200~one\ntwo\e[201~")
    prompt = screen(app).select { |l| l.start_with?("  │") }.map { |l| l.delete("│").strip }
    expect(prompt.join("\n").strip).to eq("one\ntwo")
  end

  it "paints no frames while a paste is still arriving" do
    press(app, "n")
    allow(terminal).to receive(:paint).and_call_original
    press(app, "\e[200~", *("word " * 200).chars, "\e[201~")
    expect(terminal).to have_received(:paint).once
    expect(screen(app).join).to include("[Pasted text #1 1000 chars]")
  end

  it "drops a paste that lands where nothing is typed, so its letters never act as keys" do
    press(app, ctrl_x, "\e[200~yes, every directory\e[201~")
    expect(app).to paint("Delete comma3x not booting?")
    expect(client.removed).to be_empty
    press(app, "\e", "N", "\e[200~query\e[201~")
    expect(app).to paint("Pair a phone")
    press(app, "\e", "\e[200~q\e[201~")
    expect(app).to paint("comma3x not booting")
  end

  describe "offering the Claude Code pane on the first launch without it" do
    let(:tmp) { Dir.mktmpdir }
    let(:settings) { File.join(tmp, "settings.json") }
    let(:offer) { ClaudeInbox::Mod::Offer.new(marker: File.join(tmp, "pane-offered"), settings: settings, link: File.join(tmp, "mod")) }
    let(:app) { build_app(client:, store:, pull_requests:, queue:, terminal:, trust: -> { trusted }, pane_offer: offer) }

    after { FileUtils.rm_rf(tmp) }

    it "adds the pane to Claude Code's settings on y" do
      expect(app).to paint("docked beside the transcript")
      press(app, "y")
      expect(app).to paint("added the pane").in_status_line
      expect(JSON.parse(File.read(settings))["env"]["CLAUDE_CODE_PLUGIN_DIRS"]).to eq(File.join(tmp, "mod"))
    end

    it "leaves the settings alone when dismissed, and does not ask again" do
      press(app, "\e")
      expect(app).not_to paint("docked beside the transcript")
      expect(File.exist?(settings)).to be(false)
      expect(offer.take).to be(false)
    end
  end

  describe "N with the listener on" do
    let(:tmp) { Dir.mktmpdir }
    let(:gate) { Queue.new }
    let(:pairing) do
      ClaudeInbox::Remote::Pairing.new(
        path: File.join(tmp, "listen.json"),
        local_name: -> { "m" },
        addresses: -> { [] }
      ).tap do |p|
        allow(p).to receive(:urls).and_wrap_original do |urls, **kw|
          gate.pop
          urls.call(**kw)
        end
      end
    end
    let(:app) do
      build_app(
        client:, store:, pull_requests:, queue:, terminal:,
        listen: {port: 0, pairing: pairing, lock_path: File.join(tmp, "listen.lock"), images_dir: File.join(tmp, "images")}
      )
    end
    let(:listener) { app.instance_variable_get(:@listener) }

    before { listener.start }

    after do
      gate.close
      listener.stop
      FileUtils.remove_entry(tmp)
    end

    it "shows the port in the header, and the URL once the lookup lands" do
      expect(app).to paint("◉ :#{listener.port}").in_status_line
      press(app, "N")
      expect(app).to paint("listening on 127.0.0.1:#{listener.port}")
      expect(app).to paint("looking up this Mac's addresses…")
      press(app, "c")
      expect(app).to paint("still looking up this Mac's addresses").in_status_line
      gate << true
      expect(wait_for { screen(app).join("\n").include?("http://127.0.0.1:#{listener.port}/#") }).to be(true)
    end

    it "issues a new token on r then y, and says phones must pair again" do
      old = pairing.token
      press(app, "N", "r")
      expect(app).to paint("rotate? y/n")
      gate << true << true
      press(app, "y")
      expect(wait_for { screen(app).first.include?("new token: phones pair again with N") }).to be(true)
      expect(JSON.parse(File.read(File.join(tmp, "listen.json")))["token"]).not_to eq(old)
    end
  end

  describe "N" do
    it "opens the pairing dialog, which says how to turn the listener on while it is off" do
      press(app, "N")
      expect(app).to paint("off: start with --listen or --listen-lan")
      expect(app).to paint("esc close")
      press(app, "c", "r", "y")
      expect(app).not_to paint("rotate?")
      expect(app).to paint("Pair a phone")
      press(app, "\e")
      expect(app).not_to paint("Pair a phone")
    end
  end
end
