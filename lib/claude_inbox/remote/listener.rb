# frozen_string_literal: true

require "fileutils"
require "json"
require "socket"
require_relative "../agents_client"
require_relative "http"
require_relative "pairing"
require_relative "pairing_dialog"
require_relative "start"
require_relative "../subprocess"
require_relative "../text"

module ClaudeInbox
  module Remote
    # The opt-in HTTP listener a phone starts sessions through: the port, the
    # connection limits, the static files and the Pairing token, in front of
    # Start. Like the Poller it reaches App only through the queue, and it
    # never writes to the terminal: every failure becomes a response or a
    # notice.
    class Listener
      DEFAULT_PORT = 7433
      DEFAULT_MODES = %w[default auto plan].freeze
      LOCK_PATH = File.join(Dir.home, ".config", "claude-inbox", "listen.lock")
      MAX_CONNECTIONS = 4
      # Per host, so one host's idle sockets can't shut the others out. Two,
      # so a phone loading the page doesn't turn its own requests away.
      MAX_UNAUTHENTICATED = 2
      MAX_TURNED_AWAY = 8
      RETRY_EVERY = 5
      WAITING = %i[in_use held].freeze
      HEAD_TIMEOUT = 10
      LINGER = 2
      RECENT = 5
      # The phone's form. Everything it needs is inline, and it talks to
      # nothing but this listener.
      PAGE = File.read(File.join(__dir__, "page.html"), encoding: Encoding::UTF_8).freeze
      PAGE_TYPE = {
        "Content-Type" => "text/html; charset=utf-8",
        "Content-Security-Policy" => "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; " \
          "img-src blob: data:; connect-src 'self'; manifest-src 'self'; form-action 'none'; frame-ancestors 'none'"
      }.freeze
      # What Add to Home Screen reads to open the page as an app of its own.
      # The icon is drawn by icon.svg: rsvg-convert -w 512 icon.svg -o icon.png
      MANIFEST = JSON.generate(name: "Claude Inbox", start_url: "/", scope: "/", display: "standalone",
        icons: [{src: "/icon.png", sizes: "512x512", type: "image/png"}]).freeze
      ICON = File.binread(File.join(__dir__, "icon.png")).freeze
      # Served to anyone, like the page itself: none of it is a secret.
      FILES = {
        "/" => [PAGE_TYPE, PAGE],
        "/manifest.webmanifest" => [{"Content-Type" => "application/manifest+json"}, MANIFEST],
        "/icon.png" => [{"Content-Type" => "image/png"}, ICON]
      }.freeze
      ROUTES = FILES.transform_values { "GET" }.merge(Start::VERBS).freeze

      # What `N` and the header chip show, as of one moment. `state` is :off,
      # :listening, :in_use (the port is taken), :held (another inbox has the
      # lock, as `held_by`) or :failed (for good, as `error` says). `urls` and
      # `firewall` are nil until `refresh`.
      Snapshot = Data.define(:state, :port, :lan, :urls, :firewall, :allowed_modes, :recent, :held_by, :fixture, :error) do
        def initialize(error: nil, **) = super

        # Over a VPN only an address reaches the Mac: multicast DNS, which
        # the .local name needs, stays on the LAN.
        def pairing_url = (lan && urls&.[](1)) || urls&.first
      end

      # `count` is how many times `via` got `result`, the last at `at`.
      Outcome = Data.define(:at, :via, :result, :count) do
        def initialize(at:, via:, result:, count: 1) = super
      end

      # App's `listen:` from the flags, else the environment; nil when neither
      # asks for it. --listen-lan wins over --listen, whichever came last.
      def self.options(argv, env)
        flags = argv.filter_map { |arg| arg.match(/\A--listen(-lan)?(?:=(.*))?\z/) }
        lan, port =
          if flags.any?
            flag = flags.reverse.find { |m| m[1] } || flags.last
            [!flag[1].nil?, flag[2]]
          elsif !(value = env["CLAUDE_INBOX_LISTEN"].to_s.strip).empty?
            m = value.match(/\A(?:(lan)(?::(.*))?|(\d+))\z/i)
            raise ArgumentError, "CLAUDE_INBOX_LISTEN is a port, lan or lan:PORT, not #{value}" unless m
            [!m[1].nil?, m[2] || m[3]]
          else
            return nil
          end
        modes = argv.filter_map { |arg| arg[/\A--listen-allow-modes=(.*)\z/, 1] }.last || env["CLAUDE_INBOX_LISTEN_ALLOW_MODES"]
        {port: port_option(port), lan: lan, allowed_modes: modes_option(modes)}
      end

      def self.port_option(value)
        return DEFAULT_PORT if value.nil?
        raise ArgumentError, "the listen port is a number up to 65535, not #{value}" unless value.match?(/\A\d{1,5}\z/) && value.to_i <= 65_535
        value.to_i
      end

      def self.modes_option(value)
        return DEFAULT_MODES if value.nil? || value.strip.empty?
        modes = value.split(",").map(&:strip).reject(&:empty?)
        unknown = modes - AgentsClient::PERMISSION_MODES
        raise ArgumentError, "unknown permission mode #{unknown.first}: one of #{AgentsClient::PERMISSION_MODES.join(", ")}" if unknown.any?
        modes.uniq.freeze
      end
      private_class_method :port_option, :modes_option

      # For tests, --fixture without a listen flag, and anything embedding
      # App: never binds, and answers :off.
      def self.disabled = new(client: nil, store: nil, queue: nil, pairing: nil, port: nil)

      # `start_options` are Start's own.
      def initialize(client:, store:, queue:, port:, pairing: Pairing.new, lan: false, allowed_modes: DEFAULT_MODES,
        lock_path: LOCK_PATH, fixture: false, retry_every: RETRY_EVERY, **start_options)
        @queue = queue
        @pairing = pairing
        @port = port
        @lan = lan
        @allowed_modes = allowed_modes
        @lock_path = lock_path
        @fixture = fixture
        @retry_every = retry_every
        @start = Start.new(client: client, store: store, queue: queue, allowed_modes: allowed_modes,
          fixture: fixture, **start_options)
        @mutex = Mutex.new
        @state = :off
        @recent = []
        @threads = Set.new
        @alive = 0
        @unauthenticated = Hash.new(0)
        @turning_away = 0
      end

      # Tries again every few seconds while the port is taken or another
      # inbox has the listener, so this one takes over once it is free.
      def start
        return if @port.nil? || @accept || @retry || !WAITING.include?(claim_port)
        @retry = Thread.new { retry_claim }
      end

      # Runs after the terminal is restored and can't fail, so a bad socket
      # never leaves the terminal raw.
      def stop
        quietly { @retry&.kill }
        quietly { @accept&.kill }
        quietly { @mutex.synchronize { @threads.to_a }.each(&:kill) }
        quietly { @server&.close }
        release_lock
        @mutex.synchronize { @state = :off }
      end

      def port = @bound_port || @port

      def snapshot
        @mutex.synchronize do
          Snapshot.new(state: @state, port: port, lan: @lan, urls: @urls, firewall: @firewall, allowed_modes: @allowed_modes,
            recent: @recent.dup.freeze, held_by: @held_by, fixture: @fixture, error: @error)
        end
      end

      # Looks up the pairing URLs and the firewall for the snapshot. It
      # forks, so it runs off the main thread, when `N` opens; asked for
      # before the port is ours, it runs once it is.
      def refresh
        @refresh_wanted = true
        return unless snapshot.state == :listening
        urls = @pairing.urls(port: port, lan: @lan).freeze
        firewall = @pairing.firewall if @lan
        @mutex.synchronize do
          @urls = urls
          @firewall = firewall
        end
      end

      # The addresses fork scutil, so they fill in once looked up.
      def pairing_dialog
        in_background { refresh }
        PairingDialog.new(-> { snapshot })
      end

      def copy_pairing_url
        url = snapshot.pairing_url
        return @queue << [:notice, "still looking up this Mac's addresses"] unless url
        in_background do
          r = Subprocess.capture("osascript", "-e", "on run argv", "-e", "set the clipboard to item 1 of argv", "-e", "end run", url)
          @queue << [:notice, r.success? ? "pairing URL copied" : "couldn't copy: #{r.err.strip}"]
        end
      end

      def rotate
        in_background do
          @pairing.rotate!
          refresh
          @queue << [:notice, "new token: phones pair again with N"]
        end
      end

      # One request read from `io` and answered on it. The connection's
      # `slot` stops counting as unauthenticated once the token checks out.
      def handle(io, via:, slot: nil)
        authorized = false
        request = Http.read_head(io, deadline: Http.monotonic + HEAD_TIMEOUT)
        file = route(request)
        return Http.write(io, 200, *file) if file
        authorize(request, via)
        authorized = true
        authenticated(slot) if slot
        Http.write(io, *answer(request, io, via))
      rescue Http::Error => e
        Http.write(io, e.status, Http::JSON_TYPE.merge(e.headers), JSON.generate(e.body))
      rescue => e
        # A message can name a path under the home directory, which is
        # nobody's business before the token checks out.
        Http.write(io, 500, Http::JSON_TYPE, JSON.generate(error: authorized ? Http.utf8(e.message) : "internal error"))
      end

      private

      # Without SO_REUSEADDR the bind fails while another program holds the
      # port on any address, rather than sharing it (macOS gives loopback to
      # the more specific bind); the cost is a bind refused during TIME_WAIT.
      def claim_port
        return :held unless take_lock
        server = Socket.new(:INET, :STREAM)
        server.bind(Addrinfo.tcp(@lan ? "0.0.0.0" : "127.0.0.1", @port))
        server.listen(8)
        @server = server
        @bound_port = server.local_address.ip_port
        @mutex.synchronize { @state = :listening }
        @accept = Thread.new { accept_loop }
        refresh_quietly if @refresh_wanted
        :listening
      rescue Errno::EADDRINUSE
        give_up(server, :in_use)
      rescue SystemCallError => e
        give_up(server, :failed, e.message)
      end

      def retry_claim
        loop do
          sleep @retry_every
          break unless WAITING.include?(claim_port)
        end
      end

      def give_up(server, state, error = nil)
        quietly { server&.close }
        release_lock
        @mutex.synchronize do
          @state = state
          @error = error && Text.printable(error)
        end
        state
      end

      # On the retry thread, where nothing would report a failure; the dialog
      # just goes on saying it is looking the addresses up.
      def refresh_quietly
        refresh
      rescue
        nil
      end

      def take_lock
        FileUtils.mkdir_p(File.dirname(@lock_path))
        file = File.open(@lock_path, File::RDWR | File::CREAT, 0o600)
        if file.flock(File::LOCK_EX | File::LOCK_NB)
          file.truncate(0)
          file.write(Process.pid.to_s)
          file.flush
          @mutex.synchronize { @held_by = nil }
          @lock = file
        else
          holder = file.read.to_i
          file.close
          @mutex.synchronize do
            @state = :held
            @held_by = holder.positive? ? holder : nil
          end
          nil
        end
      end

      def release_lock
        quietly { @lock&.close }
        @lock = nil
      end

      # Only closing the socket ends it; anything else, a full file table
      # say, is waited out.
      def accept_loop
        loop do
          sock, addr = @server.accept
          admit(sock, peer(addr))
        rescue IOError
          break
        rescue
          sleep 0.1
        end
      end

      def peer(addr) = addr.ip_address

      def admit(sock, via)
        slot = @mutex.synchronize { take_slot(via) }
        return quietly { sock.close } unless slot
        thread = Thread.new { serve(sock, slot) }
        @mutex.synchronize { @threads << thread if thread.alive? }
      rescue ThreadError
        quietly { sock.close }
        free(slot)
      end

      # Over the cap, a 503 rather than a queue. It lingers like any answer,
      # so it isn't lost to a reset; past a few of those, only a close.
      def take_slot(via)
        if @alive < MAX_CONNECTIONS && @unauthenticated[via] < MAX_UNAUTHENTICATED
          @alive += 1
          @unauthenticated[via] += 1
          {via: via, authenticated: false}
        elsif @turning_away < MAX_TURNED_AWAY
          @turning_away += 1
          {busy: true}
        end
      end

      def free(slot)
        @mutex.synchronize do
          if slot[:busy] then @turning_away -= 1
          else
            @alive -= 1
            release_unauthenticated(slot[:via]) unless slot[:authenticated]
          end
        end
      end

      # Under the mutex. A host leaves the hash at zero, so it holds only
      # hosts connected now.
      def release_unauthenticated(via)
        @unauthenticated[via] -= 1
        @unauthenticated.delete(via) if @unauthenticated[via].zero?
      end

      # `handle` answers every failure it can; what is left is the socket
      # itself going away, and a thread must not report that on stderr.
      def serve(sock, slot)
        if slot[:busy]
          Http.write(sock, 503, Http::JSON_TYPE.merge("Retry-After" => "2"), JSON.generate(error: "busy: try again in a moment"))
        else
          handle(sock, via: slot[:via], slot: slot)
        end
        linger(sock)
      rescue
        nil
      ensure
        quietly { sock.close }
        free(slot)
        @mutex.synchronize { @threads.delete(Thread.current) }
      end

      def authenticated(slot)
        @mutex.synchronize do
          release_unauthenticated(slot[:via]) unless slot[:authenticated]
          slot[:authenticated] = true
        end
      end

      # The client closes first: a close on unread bytes resets the answer,
      # and a server-side close leaves the TIME_WAIT that refuses a rebind.
      def linger(sock)
        deadline = Http.monotonic + LINGER
        loop do
          left = deadline - Http.monotonic
          break unless left > 0 && IO.select([sock], nil, nil, left)
          break if sock.read_nonblock(Http::CHUNK, exception: false).nil?
        end
      end

      # The file a path serves to anyone, or nil for one Start answers.
      def route(request)
        raise Http::Error.new(405, "only GET and POST", headers: {"Allow" => "GET, POST"}) unless %w[GET POST].include?(request.verb)
        raise Http::Error.new(421, "the Host header isn't a name this inbox answers to") unless @pairing.hosts(lan: @lan).include?(host(request))
        verb = ROUTES[request.path]
        raise Http::Error.new(404, "no such path") unless verb
        raise Http::Error.new(405, "#{request.path} takes #{verb}", headers: {"Allow" => verb}) unless request.verb == verb
        FILES[request.path]
      end

      # The name without its port: a tunnel or a proxy can change the port,
      # and only the name tells this Mac from a site pointed at it.
      def host(request) = request.headers["host"].to_s.downcase.sub(/:\d+\z/, "")

      def authorize(request, via)
        return if @pairing.matches?(request.headers["authorization"].to_s[/\ABearer +(\S+)\z/i, 1])
        remember(via, "token rejected")
        raise Http::Error.new(401, "missing or wrong token: press N in the inbox and pair again", headers: {"WWW-Authenticate" => "Bearer"})
      end

      # The same outcome from the same place again moves up with a count, so
      # a host sending bad tokens can't push everything else out of the list.
      # Every start, and every refusal once the token has checked out, is
      # listed for `N`.
      def answer(request, io, via)
        status, headers, body, note = @start.call(request, io, via)
        remember(via, note) if note
        [status, headers, body]
      rescue Http::Error => e
        remember(via, e.note || "refused: #{e.message}")
        raise
      end

      def remember(via, result)
        result = Text.printable(result)
        @mutex.synchronize do
          same = @recent.find { |o| o.via == via && o.result == result }
          outcome = Outcome.new(at: Time.now, via: via, result: result, count: (same&.count || 0) + 1)
          @recent = (@recent - [same] + [outcome]).last(RECENT)
        end
      end

      # A notice, not an :error: the next poll clears an :error.
      def in_background
        Thread.new do
          yield
        rescue => e
          @queue << [:notice, Text.printable(e.message)]
        end
      end

      def quietly
        yield
      rescue IOError, SystemCallError
        nil
      end
    end
  end
end
