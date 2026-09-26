# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/claude_inbox/pairing"
require "tmpdir"

describe ClaudeInbox::Pairing do
  let(:dir) { Dir.mktmpdir }
  let(:path) { File.join(dir, "config", "listen.json") }
  let(:addresses) { [Addrinfo.ip("127.0.0.1"), Addrinfo.ip("192.168.1.20"), Addrinfo.ip("100.100.4.2"), Addrinfo.ip("fe80::1")] }
  let(:names) { ["Mac-Mini"] }
  let(:lookups) { [] }
  let(:now) { [0.0] }
  let(:pairing) do
    ClaudeInbox::Pairing.new(path: path, local_name: -> { names.first.tap { |n| lookups << n } }, hostname: -> { "mac.mini.lan" },
      addresses: -> { addresses }, firewall: -> { :on }, clock: -> { now[0] })
  end

  after { FileUtils.remove_entry(dir) }

  describe "the token" do
    it "is issued once, readable by the owner only, and read back on the next launch" do
      token = pairing.token
      _(token.size).must_be :>=, 43
      _(pairing.token).must_equal token
      _(File.stat(path).mode & 0o777).must_equal 0o600
      _(ClaudeInbox::Pairing.new(path: path).token).must_equal token
    end

    # A temp file left by a crash already exists, so opening it with a mode
    # would change nothing; the mode has to be set on it before the write.
    it "never lands at a wider mode, even over a stale temp file" do
      FileUtils.mkdir_p(File.dirname(path))
      stale = File.join(File.dirname(path), ".listen.json.#{Process.pid}.tmp")
      File.write(stale, "old")
      File.chmod(0o644, stale)
      pairing.token
      _(File.stat(path).mode & 0o777).must_equal 0o600
    end

    it "matches only itself" do
      token = pairing.token
      _(pairing.matches?(token)).must_equal true
      _(pairing.matches?(token + "x")).must_equal false
      _(pairing.matches?(token[0..-2])).must_equal false
      _(pairing.matches?("")).must_equal false
      _(pairing.matches?(nil)).must_equal false
    end

    it "is replaced for good by rotate!, and the old one stops matching" do
      old = pairing.token
      pairing.rotate!
      _(pairing.token).wont_equal old
      _(pairing.matches?(old)).must_equal false
      _(ClaudeInbox::Pairing.new(path: path).token).must_equal pairing.token
    end

    it "is issued afresh when the file holds something that isn't one" do
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.generate(token: "short"))
      _(pairing.token).wont_equal "short"
      File.write(path, "[1, 2]")
      _(ClaudeInbox::Pairing.new(path: path).token.size).must_be :>=, 43
    end
  end

  describe "urls" do
    it "carries the token in the fragment of the loopback address" do
      _(pairing.urls(port: 7433, lan: false)).must_equal ["http://127.0.0.1:7433/##{pairing.token}"]
    end

    it "offers the Bonjour name and each private IPv4 address on the LAN" do
      _(pairing.urls(port: 7433, lan: true)).must_equal [
        "http://Mac-Mini.local:7433/##{pairing.token}", "http://192.168.1.20:7433/##{pairing.token}"
      ]
    end

    it "looks the addresses up again on every call" do
      pairing.urls(port: 7433, lan: true)
      addresses.replace([Addrinfo.ip("10.0.0.7")])
      _(pairing.urls(port: 7433, lan: true).last).must_equal "http://10.0.0.7:7433/##{pairing.token}"
    end

    # A rename is followed within seconds, but a stream of requests can't
    # make every one of them fork scutil.
    it "asks for the Bonjour name again once it is ten seconds old" do
      3.times { pairing.hosts(lan: true) }
      _(lookups.size).must_equal 1
      names.replace(["Mac-Mini-2"])
      now[0] += 11
      _(pairing.hosts(lan: true)).must_include "mac-mini-2.local"
      _(pairing.urls(port: 7433, lan: true).first).must_equal "http://Mac-Mini-2.local:7433/##{pairing.token}"
      _(lookups.size).must_equal 2
    end
  end

  describe "hosts" do
    it "accepts only loopback names on loopback" do
      _(pairing.hosts(lan: false)).must_equal %w[127.0.0.1 localhost [::1]]
      _(lookups).must_be_empty
    end

    it "adds this Mac's names and every IPv4 address in LAN mode, in lower case" do
      _(pairing.hosts(lan: true)).must_equal %w[127.0.0.1 localhost [::1] mac-mini mac-mini.local mac.mini.lan 192.168.1.20 100.100.4.2]
    end
  end

  it "lists Ethernet and Wi-Fi addresses ahead of a VM's bridge, so c copies one a phone can reach" do
    interface = Struct.new(:name, :addr)
    interfaces = [
      interface.new("lo0", Addrinfo.ip("127.0.0.1")), interface.new("bridge100", Addrinfo.ip("192.168.64.1")),
      interface.new("utun3", nil), interface.new("en1", Addrinfo.ip("192.168.1.20"))
    ]
    _(ClaudeInbox::Pairing.addresses(interfaces).map(&:ip_address)).must_equal %w[192.168.1.20 127.0.0.1 192.168.64.1]
    _(ClaudeInbox::Pairing.addresses).wont_be_empty
  end
end
