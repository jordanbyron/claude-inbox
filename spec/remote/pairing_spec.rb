# frozen_string_literal: true

require_relative "../../lib/claude_inbox/remote/pairing"
require "tmpdir"

RSpec.describe ClaudeInbox::Remote::Pairing do
  let(:dir) { Dir.mktmpdir }
  let(:path) { File.join(dir, "config", "listen.json") }
  let(:addresses) { [Addrinfo.ip("127.0.0.1"), Addrinfo.ip("192.168.1.20"), Addrinfo.ip("100.100.4.2"), Addrinfo.ip("fe80::1")] }
  let(:names) { ["Mac-Mini"] }
  let(:lookups) { [] }
  let(:now) { [0.0] }
  let(:pairing) do
    ClaudeInbox::Remote::Pairing.new(path: path, local_name: -> { names.first.tap { |n| lookups << n } }, hostname: -> { "mac.mini.lan" },
      addresses: -> { addresses }, firewall: -> { :on }, clock: -> { now[0] })
  end

  after { FileUtils.remove_entry(dir) }

  describe "the token" do
    it "is issued once, readable by the owner only, and read back on the next launch" do
      token = pairing.token
      expect(token.size).to be >= 43
      expect(pairing.token).to eq(token)
      expect(File.stat(path).mode & 0o777).to eq(0o600)
      expect(ClaudeInbox::Remote::Pairing.new(path: path).token).to eq(token)
    end

    # A temp file left by a crash already exists, so opening it with a mode
    # would change nothing; the mode has to be set on it before the write.
    it "never lands at a wider mode, even over a stale temp file" do
      FileUtils.mkdir_p(File.dirname(path))
      stale = File.join(File.dirname(path), ".listen.json.#{Process.pid}.tmp")
      File.write(stale, "old")
      File.chmod(0o644, stale)
      pairing.token
      expect(File.stat(path).mode & 0o777).to eq(0o600)
    end

    it "matches only itself" do
      token = pairing.token
      expect(pairing.matches?(token)).to be(true)
      expect(pairing.matches?(token + "x")).to be(false)
      expect(pairing.matches?(token[0..-2])).to be(false)
      expect(pairing.matches?("")).to be(false)
      expect(pairing.matches?(nil)).to be(false)
    end

    it "is replaced for good by rotate!, and the old one stops matching" do
      old = pairing.token
      pairing.rotate!
      expect(pairing.token).not_to eq(old)
      expect(pairing.matches?(old)).to be(false)
      expect(ClaudeInbox::Remote::Pairing.new(path: path).token).to eq(pairing.token)
    end

    it "is issued afresh when the file holds something that isn't one" do
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.generate(token: "short"))
      expect(pairing.token).not_to eq("short")
      File.write(path, "[1, 2]")
      expect(ClaudeInbox::Remote::Pairing.new(path: path).token.size).to be >= 43
    end
  end

  describe "urls" do
    it "carries the token in the fragment of the loopback address" do
      expect(pairing.urls(port: 7433, lan: false)).to eq(["http://127.0.0.1:7433/##{pairing.token}"])
    end

    it "offers the Bonjour name and each private IPv4 address on the LAN" do
      expect(pairing.urls(port: 7433, lan: true)).to eq([
        "http://Mac-Mini.local:7433/##{pairing.token}", "http://192.168.1.20:7433/##{pairing.token}"
      ])
    end

    it "looks the addresses up again on every call" do
      pairing.urls(port: 7433, lan: true)
      addresses.replace([Addrinfo.ip("10.0.0.7")])
      expect(pairing.urls(port: 7433, lan: true).last).to eq("http://10.0.0.7:7433/##{pairing.token}")
    end

    # A rename is followed within seconds, but a stream of requests can't
    # make every one of them fork scutil.
    it "asks for the Bonjour name again once it is ten seconds old" do
      3.times { pairing.hosts(lan: true) }
      expect(lookups.size).to eq(1)
      names.replace(["Mac-Mini-2"])
      now[0] += 11
      expect(pairing.hosts(lan: true)).to include("mac-mini-2.local")
      expect(pairing.urls(port: 7433, lan: true).first).to eq("http://Mac-Mini-2.local:7433/##{pairing.token}")
      expect(lookups.size).to eq(2)
    end
  end

  describe "hosts" do
    it "accepts only loopback names on loopback" do
      expect(pairing.hosts(lan: false)).to eq(%w[127.0.0.1 localhost [::1]])
      expect(lookups).to be_empty
    end

    it "adds this Mac's names and every IPv4 address in LAN mode, in lower case" do
      expect(pairing.hosts(lan: true)).to eq(%w[127.0.0.1 localhost [::1] mac-mini mac-mini.local mac.mini.lan 192.168.1.20 100.100.4.2])
    end
  end

  it "lists Ethernet and Wi-Fi addresses ahead of a VM's bridge, so c copies one a phone can reach" do
    interface = Struct.new(:name, :addr)
    interfaces = [
      interface.new("lo0", Addrinfo.ip("127.0.0.1")), interface.new("bridge100", Addrinfo.ip("192.168.64.1")),
      interface.new("utun3", nil), interface.new("en1", Addrinfo.ip("192.168.1.20"))
    ]
    expect(ClaudeInbox::Remote::Pairing.addresses(interfaces).map(&:ip_address)).to eq(%w[192.168.1.20 127.0.0.1 192.168.64.1])
    expect(ClaudeInbox::Remote::Pairing.addresses).not_to be_empty
  end
end
