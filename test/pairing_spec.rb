# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/claude_inbox/pairing"
require "tmpdir"

describe ClaudeInbox::Pairing do
  let(:dir) { Dir.mktmpdir }
  let(:path) { File.join(dir, "config", "listen.json") }
  let(:addresses) { [Addrinfo.ip("127.0.0.1"), Addrinfo.ip("192.168.1.20"), Addrinfo.ip("100.100.4.2"), Addrinfo.ip("fe80::1")] }
  let(:pairing) do
    ClaudeInbox::Pairing.new(path: path, local_name: -> { "Mac-Mini" }, hostname: -> { "mac.mini.lan" },
      addresses: -> { addresses }, firewall: -> { :on })
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

    it "looks the names and addresses up again on every call" do
      pairing.urls(port: 7433, lan: true)
      addresses.replace([Addrinfo.ip("10.0.0.7")])
      _(pairing.urls(port: 7433, lan: true).last).must_equal "http://10.0.0.7:7433/##{pairing.token}"
    end
  end

  describe "hosts" do
    it "accepts only loopback names on loopback, with and without the port" do
      _(pairing.hosts(port: 7433, lan: false)).must_equal %w[127.0.0.1 127.0.0.1:7433 localhost localhost:7433 [::1] [::1]:7433]
    end

    it "adds this Mac's names and every IPv4 address in LAN mode, in lower case" do
      hosts = pairing.hosts(port: 7433, lan: true)
      %w[mac-mini mac-mini.local mac-mini.local:7433 mac.mini.lan:7433 192.168.1.20:7433 100.100.4.2 localhost:7433].each do |host|
        _(hosts).must_include host
      end
      _(hosts).wont_include "Mac-Mini.local"
      _(hosts.grep(/fe80/)).must_be_empty
      _(hosts).wont_include "mac-mini.local:7434"
    end
  end
end
