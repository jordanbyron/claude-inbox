# frozen_string_literal: true

require "openssl"
require "securerandom"
require "socket"
require_relative "../records"
require_relative "../subprocess"

module ClaudeInbox
  # The token a phone pairs with, and the names and addresses it can reach
  # this Mac by. Those are looked up again rather than kept: macOS renames
  # the Bonjour host after a clash, and joining another network brings
  # another address.
  class Pairing
    DEFAULT_PATH = File.join(Dir.home, ".config", "claude-inbox", "listen.json")
    FIREWALL = "/usr/libexec/ApplicationFirewall/socketfilterfw"
    FIREWALL_STATES = {"0" => :off, "1" => :on, "2" => :block_all}.freeze
    NAME_TTL = 10

    # The Bonjour name, which is the one a phone on the same Wi-Fi resolves.
    def self.local_host_name
      r = Subprocess.capture("scutil", "--get", "LocalHostName")
      name = r.out.strip if r.success?
      (name.nil? || name.empty?) ? Socket.gethostname.sub(/\.local\z/i, "") : name
    end

    # Ethernet and Wi-Fi (en*) first: the first private address is the one
    # `c` copies, and a VM's bridge is no use to a phone.
    def self.addresses(interfaces = Socket.getifaddrs)
      interfaces.select { |i| i.addr&.ip? }.sort_by.with_index { |i, n| [i.name.start_with?("en") ? 0 : 1, n] }.map(&:addr)
    end

    # :off, :on or :block_all; nil without macOS's application firewall.
    def self.firewall_state
      return nil unless File.executable?(FIREWALL)
      r = Subprocess.capture(FIREWALL, "--getglobalstate")
      FIREWALL_STATES[r.out[/State = (\d)/, 1]] if r.success?
    end

    def initialize(path: DEFAULT_PATH, local_name: -> { Pairing.local_host_name }, hostname: -> { Socket.gethostname },
      addresses: -> { Pairing.addresses }, firewall: -> { Pairing.firewall_state },
      clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @path = path
      @lookup_name = local_name
      @hostname = hostname
      @addresses = addresses
      @firewall = firewall
      @clock = clock
      @mutex = Mutex.new
      @names = Mutex.new
    end

    def token = @mutex.synchronize { @token ||= stored || issue }

    def rotate! = @mutex.synchronize { @token = issue }

    # Compared as digests, which are always the same length, so the time
    # taken says nothing about how much of a guess was right.
    def matches?(sent)
      return false unless sent.is_a?(String) && !sent.empty?
      OpenSSL.fixed_length_secure_compare(digest(sent), digest(token))
    end

    # The token rides in the fragment, which a browser never sends, so it
    # stays out of the request line and any log of it.
    def urls(port:, lan:)
      secret = token
      hosts = lan ? ["#{local_name}.local", *ipv4s.select(&:ipv4_private?).map(&:ip_address)] : ["127.0.0.1"]
      hosts.map { |host| "http://#{host}:#{port}/##{secret}" }
    end

    # Names a request's Host header may carry, lower case and without the
    # port. Anything else is a page on another site whose name was pointed
    # at this machine.
    def hosts(lan:)
      names = %w[127.0.0.1 localhost [::1]]
      names += [local_name, "#{local_name}.local", @hostname.call, *ipv4s.map(&:ip_address)] if lan
      names.map(&:downcase).uniq
    end

    def firewall = @firewall.call

    private

    # Asked again at most every NAME_TTL seconds: often enough to follow a
    # rename, and a stream of requests can't make each one fork scutil.
    def local_name
      @names.synchronize do
        now = @clock.call
        @local = [@lookup_name.call, now] unless @local && now - @local[1] < NAME_TTL
        @local[0]
      end
    end

    def ipv4s = @addresses.call.select { |a| a.ipv4? && !a.ipv4_loopback? }

    def stored
      data = Records.read(@path)
      secret = data["token"] if data.is_a?(Hash)
      secret if secret.is_a?(String) && secret.length >= 32
    end

    def issue
      SecureRandom.urlsafe_base64(32).tap { |secret| Records.save(@path, {"token" => secret}, perm: 0o600) }
    end

    def digest(text) = OpenSSL::Digest.digest("SHA256", text)
  end
end
