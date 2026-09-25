# frozen_string_literal: true

require "fileutils"
require "json"
require "socket"
require_relative "agents_client"
require_relative "http"
require_relative "images"
require_relative "job_state"
require_relative "session"
require_relative "session_request"
require_relative "settings"
require_relative "trust"

module ClaudeInbox
  # Starts sessions for another device: an opt-in HTTP listener, gated by
  # the Pairing token, that turns a JSON request into the same
  # AgentsClient#spawn the `n` form makes. Like the Poller it reaches App
  # only through the queue, and it never writes to the terminal: every
  # failure becomes a response.
  class Listener
    DEFAULT_PORT = 7433
    DEFAULT_MODES = %w[default plan].freeze
    LOCK_PATH = File.join(Dir.home, ".config", "claude-inbox", "listen.lock")
    MAX_CONNECTIONS = 4
    MAX_UNAUTHENTICATED = 2
    MAX_BODY = 16 * 1024 * 1024
    MAX_IMAGES = 8
    HEAD_TIMEOUT = 10
    BODY_TIMEOUT = 120
    LINGER = 2
    KEYS_KEPT = 16
    RECENT = 5
    ROUTES = {"/" => "GET", "/api/options" => "GET", "/api/sessions" => "POST"}.freeze
    JSON_TYPE = {"Content-Type" => "application/json"}.freeze
    PAGE_TYPE = {
      "Content-Type" => "text/html; charset=utf-8",
      "Content-Security-Policy" => "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'"
    }.freeze
    PAGE = <<~HTML
      <!doctype html>
      <html lang="en">
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>claude-inbox</title>
      <style>body { font: 17px/1.5 -apple-system, system-ui, sans-serif; margin: 2em auto; max-width: 32em; padding: 0 1em; }</style>
      <h1>claude-inbox is listening</h1>
      <p>The form for starting a session from this page isn't here yet. Until it is,
      send <code>POST /api/sessions</code> with your pairing token, as the README shows.</p>
      </html>
    HTML

    # What `N` and the header chip show, as of one moment. `state` is :off,
    # :listening, :in_use (the bind failed) or :held (another inbox has the
    # lock, as `held_by`). `urls` and `firewall` are nil until `refresh`.
    Snapshot = Data.define(:state, :port, :lan, :urls, :firewall, :allowed_modes, :recent, :held_by, :fixture) do
      # Over a VPN only an address reaches the Mac: multicast DNS, which
      # the .local name needs, stays on the LAN.
      def pairing_url = (lan && urls&.[](1)) || urls&.first
    end

    Outcome = Data.define(:at, :via, :result)

    # --listen[=PORT], --listen-lan[=PORT] and --listen-allow-modes=a,b, or
    # the CLAUDE_INBOX_LISTEN* variables when no listen flag is given, as
    # App's `listen:`; nil when nothing asks for it. ArgumentError on a
    # value that can't be used. --listen-lan wins over --listen: widening to
    # the LAN is never an accident of which came last.
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

    def initialize(client:, store:, queue:, pairing:, port:, lan: false, allowed_modes: DEFAULT_MODES,
      images_dir: Images::DEFAULT_DIR, jobs_dir: JobState::DEFAULT_DIR, lock_path: LOCK_PATH, fixture: false,
      trust: Trust.method(:projects), settings: Settings.method(:defaults), bridge_wait: 3)
      @client = client
      @store = store
      @queue = queue
      @pairing = pairing
      @port = port
      @lan = lan
      @allowed_modes = allowed_modes
      @images_dir = images_dir
      @jobs_dir = jobs_dir
      @lock_path = lock_path
      @fixture = fixture
      @trust = trust
      @settings = settings
      @bridge_wait = bridge_wait
      @mutex = Mutex.new
      @spawn_lock = Mutex.new
      @state = :off
      @keys = {}
      @recent = []
      @threads = Set.new
      @alive = 0
      @unauthenticated = 0
    end

    # One listener per user: the lock file keeps a second inbox from
    # binding at all. The socket is bound without SO_REUSEADDR, which on
    # macOS would let another program hold the same port on a different
    # address and quietly take the loopback traffic.
    def start
      return if @port.nil? || @accept
      return unless take_lock
      @server = Socket.new(:INET, :STREAM)
      @server.bind(Addrinfo.tcp(@lan ? "0.0.0.0" : "127.0.0.1", @port))
      @server.listen(8)
      @bound_port = @server.local_address.ip_port
      @mutex.synchronize { @state = :listening }
      @accept = Thread.new { accept_loop }
    rescue SystemCallError
      quietly { @server&.close }
      @server = nil
      release_lock
      @mutex.synchronize { @state = :in_use }
    end

    # Runs after the terminal is restored and can't fail, so a bad socket
    # never leaves the terminal raw.
    def stop
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
          recent: @recent.dup.freeze, held_by: @held_by, fixture: @fixture)
      end
    end

    # Looks up the pairing URLs and the firewall for the snapshot. It
    # forks, so it runs off the main thread, when `N` opens.
    def refresh
      return unless snapshot.state == :listening
      urls = @pairing.urls(port: port, lan: @lan).freeze
      firewall = @pairing.firewall if @lan
      @mutex.synchronize do
        @urls = urls
        @firewall = firewall
      end
    end

    def rotate
      @pairing.rotate!
      refresh
    end

    # One request read from `io` and answered on it. `on_auth` runs once
    # the token checks out, which frees the slot the connection held as an
    # unauthenticated one.
    def handle(io, via:, on_auth: -> {})
      request = Http.read_head(io, deadline: Http.monotonic + HEAD_TIMEOUT)
      status, headers, body = route(io, request, via, on_auth)
      Http.write(io, status, headers, body)
    rescue Http::Error => e
      Http.write(io, e.status, JSON_TYPE.merge(e.headers), JSON.generate(e.body))
    rescue => e
      Http.write(io, 500, JSON_TYPE, JSON.generate(error: Http.utf8(e.message)))
    end

    private

    def take_lock
      FileUtils.mkdir_p(File.dirname(@lock_path))
      file = File.open(@lock_path, File::RDWR | File::CREAT, 0o600)
      if file.flock(File::LOCK_EX | File::LOCK_NB)
        file.truncate(0)
        file.write(Process.pid.to_s)
        file.flush
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
        sock, = @server.accept
        admit(sock)
      rescue IOError
        break
      rescue
        sleep 0.1
      end
    end

    # A fifth connection, or a third that hasn't shown a token, is turned
    # away rather than queued.
    def admit(sock)
      slot = @mutex.synchronize do
        next nil if @alive >= MAX_CONNECTIONS || @unauthenticated >= MAX_UNAUTHENTICATED
        @alive += 1
        @unauthenticated += 1
        {authenticated: false}
      end
      return turn_away(sock) unless slot
      thread = Thread.new { serve(sock, slot) }
      @mutex.synchronize { @threads << thread if thread.alive? }
    end

    def turn_away(sock)
      Http.write(sock, 503, JSON_TYPE.merge("Retry-After" => "2"), JSON.generate(error: "busy: try again in a moment"))
    rescue IOError, SystemCallError
      nil
    ensure
      quietly { sock.close }
    end

    # `handle` answers every failure it can; what is left is the socket
    # itself going away, and a thread must not report that on stderr.
    def serve(sock, slot)
      handle(sock, via: sock.remote_address.ip_address, on_auth: -> { authenticated(slot) })
      linger(sock)
    rescue
      nil
    ensure
      quietly { sock.close }
      @mutex.synchronize do
        @alive -= 1
        @unauthenticated -= 1 unless slot[:authenticated]
        @threads.delete(Thread.current)
      end
    end

    def authenticated(slot)
      @mutex.synchronize do
        @unauthenticated -= 1 unless slot[:authenticated]
        slot[:authenticated] = true
      end
    end

    # Waits for the client to close first. Whichever side closes first
    # keeps the port in TIME_WAIT, and without SO_REUSEADDR that fails the
    # next inbox's bind for half a minute. Reading also drains a body sent
    # after a refusal, which would otherwise turn the close into a reset
    # that can beat the response to the client.
    def linger(sock)
      deadline = Http.monotonic + LINGER
      loop do
        left = deadline - Http.monotonic
        break unless left > 0 && IO.select([sock], nil, nil, left)
        break if sock.read_nonblock(Http::CHUNK, exception: false).nil?
      end
    end

    def route(io, request, via, on_auth)
      raise Http::Error.new(405, "only GET and POST", headers: {"Allow" => "GET, POST"}) unless %w[GET POST].include?(request.verb)
      host = request.headers["host"].to_s.downcase
      raise Http::Error.new(421, "the Host header isn't a name this inbox answers to") unless @pairing.hosts(port: port, lan: @lan).include?(host)
      verb = ROUTES[request.path]
      raise Http::Error.new(404, "no such path") unless verb
      raise Http::Error.new(405, "#{request.path} takes #{verb}", headers: {"Allow" => verb}) unless request.verb == verb
      return [200, PAGE_TYPE, PAGE] if request.path == "/"
      authorize(request, via)
      on_auth.call
      (request.path == "/api/options") ? json(200, choices) : post_session(io, request, via)
    end

    def authorize(request, via)
      return if @pairing.matches?(request.headers["authorization"].to_s[/\ABearer +(\S+)\z/i, 1])
      remember(via, "token rejected")
      raise Http::Error.new(401, "missing or wrong token: press N in the inbox and pair again", headers: {"WWW-Authenticate" => "Bearer"})
    end

    def json(status, body) = [status, JSON_TYPE, JSON.generate(@fixture ? body.merge(fixture: true) : body)]

    def choices
      paths = dir_paths
      {
        models: AgentsClient::MODELS,
        efforts: AgentsClient::EFFORTS,
        permission_modes: AgentsClient::PERMISSION_MODES & @allowed_modes,
        dirs: paths.map { |path| {path: path, label: label(path, paths), defaults: @settings.call(path).to_h} }
      }
    end

    # Where sessions ran lately, newest first, then every directory whose
    # trust dialog was accepted: the likely choices first. Only an order;
    # the CLI still decides where a session may start.
    def dir_paths
      recent = @store.sessions.sort_by { |s| -s.started_at.to_i }.filter_map { |s| s.cwd && SessionRequest.strip_worktree(s.cwd) }
      (recent + @trust.call).uniq.select { |dir| File.directory?(dir) }
    end

    # The fewest trailing components that name `path` alone among `paths`,
    # which is how SessionRequest finds a directory by label.
    def label(path, paths)
      parts = path.split("/").reject(&:empty?)
      (1..parts.size).each do |n|
        label = parts.last(n).join("/")
        return label if paths.one? { |other| other.end_with?("/#{label}") }
      end
      path
    end

    # Checked cheapest first, and nothing is written to disk until every
    # check has passed. A retry with the same Idempotency-Key gets the
    # first answer instead of a second session.
    def post_session(io, request, via)
      params = read_json(io, request)
      images = take_images(params)
      key = request.headers["idempotency-key"]
      earlier = key && claim(key)
      return json(200, earlier) if earlier
      started = nil
      begin
        started = launch(params, images, via)
        json(201, started)
      ensure
        settle(key, started) if key
      end
    rescue AgentsClient::Error => e
      reason = Http.utf8(e.message.lines.first).strip
      @queue << [:notice, "remote start failed: #{reason}"]
      remember(via, reason)
      raise Http::Error.new(500, e.message, source: "claude")
    end

    def read_json(io, request)
      type = request.headers["content-type"].to_s.split(";").first.to_s.strip
      raise Http::Error.new(415, "send the request as application/json") unless type.casecmp?("application/json")
      body = request.read_body(io, max: MAX_BODY, deadline: Http.monotonic + BODY_TIMEOUT).force_encoding(Encoding::UTF_8)
      raise Http::Error.new(400, "the body isn't UTF-8") unless body.valid_encoding?
      params = JSON.parse(body)
      raise Http::Error.new(400, "the body must be a JSON object") unless params.is_a?(Hash)
      params
    rescue JSON::ParserError
      raise Http::Error.new(400, "the body isn't JSON")
    end

    # Decoded and sniffed now, saved only once the request has passed.
    def take_images(params)
      images = params.delete("images") || []
      raise Http::Error.new(422, "images is a list of {\"data\": base64}", field: "images") unless images.is_a?(Array)
      raise Http::Error.new(413, "at most #{MAX_IMAGES} images", field: "images") if images.size > MAX_IMAGES
      images.each_with_index.map do |image, i|
        bytes = decode(image)
        next bytes if bytes && Images.extension(bytes)
        raise Http::Error.new(415, "image #{i + 1} isn't a PNG, JPEG, GIF or WebP image", field: "images", index: i)
      end
    end

    def decode(image)
      data = image["data"] if image.is_a?(Hash)
      data.gsub(/\s+/, "").unpack1("m0") if data.is_a?(String)
    rescue ArgumentError
      nil
    end

    # The body an earlier request with this key got, or nil once the key
    # is this request's; one still starting is a 409.
    def claim(key)
      @mutex.synchronize do
        earlier = @keys[key]
        raise Http::Error.new(409, "already starting") if earlier == :spawning
        return earlier if earlier
        @keys.shift while @keys.size >= KEYS_KEPT
        @keys[key] = :spawning
        nil
      end
    end

    # A failed start frees its key, so a retry goes through rather than
    # getting 409 for ever.
    def settle(key, started)
      @mutex.synchronize do
        if started then @keys[key] = started
        else @keys.delete(key)
        end
      end
    end

    def launch(params, images, via)
      values = SessionRequest.from_params(params, dirs: dir_paths)
      field, message = SessionRequest.problem(values)
      raise Http::Error.new(422, message, field: field) if field
      values[:permission_mode] = capped_mode(values)
      paths = images.each_with_index.map { |bytes, i| Images.save(bytes, dir: @images_dir, index: i + 1) }
      values[:prompt] = SessionRequest.attach(values[:prompt], paths)
      @queue << [:notice, "remote: starting session…"]
      id = Http.utf8(@spawn_lock.synchronize { @client.spawn(**values) })
      url = remote_url(id)
      @queue << [:remote_started, id, via]
      remember(via, "started #{id}")
      {id: id, name: values[:name], cwd: values[:cwd], url: url}
    rescue SessionRequest::Invalid => e
      raise Http::Error.new(422, e.message, field: e.field)
    end

    # "default" is whatever the settings files say, so the cap applies to
    # what they say: a project that defaults to bypassPermissions can't
    # slip through as "default". Settings files Settings doesn't read,
    # managed ones for instance, can still change it.
    def capped_mode(values)
      mode = values[:permission_mode]
      mode = @settings.call(values[:cwd]).permission_mode || "default" if mode == "default"
      return mode if @allowed_modes.include?(mode)
      raise Http::Error.new(403, "permission mode #{mode} isn't allowed from another device", field: "permission_mode")
    end

    # The session registers its bridge a moment after `claude --bg`
    # returns; without it in time the reply has no URL, only the id.
    def remote_url(id)
      deadline = Http.monotonic + @bridge_wait
      loop do
        url = Session.new(id: id, job_state: JobState.read(id, jobs_dir: @jobs_dir)).remote_url
        return url if url || Http.monotonic >= deadline
        sleep 0.2
      end
    end

    def remember(via, result)
      @mutex.synchronize { @recent = (@recent + [Outcome.new(at: Time.now, via: via, result: result)]).last(RECENT) }
    end

    def quietly
      yield
    rescue IOError, SystemCallError
      nil
    end
  end
end
