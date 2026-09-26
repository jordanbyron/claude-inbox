# frozen_string_literal: true

require "json"
require "openssl"
require_relative "../agents_client"
require_relative "../images"
require_relative "../job_state"
require_relative "../session"
require_relative "../session_request"
require_relative "../settings"
require_relative "../trust"
require_relative "http"

module ClaudeInbox
  module Remote
    # What a paired phone may ask for: the choices, and a session started
    # the way the `n` form starts one, within the permission cap. Listener
    # hands it a request only once the token has checked out.
    class Start
      ROUTES = {"/api/options" => "GET", "/api/sessions" => "POST"}.freeze
      MAX_BODY = 16 * 1024 * 1024
      MAX_IMAGES = 8
      BODY_TIMEOUT = 120
      KEYS_KEPT = 16

      # `record` takes (via, result) for the list `N` shows.
      def initialize(client:, store:, queue:, record:, allowed_modes:, fixture: false, images_dir: Images::DEFAULT_DIR,
        jobs_dir: JobState::DEFAULT_DIR, trust: Trust.method(:projects), settings: Settings.method(:defaults), bridge_wait: 3)
        @client = client
        @store = store
        @queue = queue
        @record = record
        @allowed_modes = allowed_modes
        @fixture = fixture
        @images_dir = images_dir
        @jobs_dir = jobs_dir
        @trust = trust
        @settings = settings
        @bridge_wait = bridge_wait
        @mutex = Mutex.new
        @spawn_lock = Mutex.new
        @keys = {}
      end

      # => [status, headers, body], or raises Http::Error.
      def call(request, io, via)
        (request.path == "/api/options") ? json(200, choices) : post_session(io, request, via)
      end

      private

      def json(status, body) = [status, Http::JSON_TYPE, JSON.generate(@fixture ? body.merge(fixture: true) : body)]

      def choices
        paths = dir_paths
        {
          models: AgentsClient::MODELS,
          efforts: AgentsClient::EFFORTS,
          permission_modes: AgentsClient::PERMISSION_MODES & @allowed_modes,
          dirs: paths.map { |path| {path: path, label: SessionRequest.label(path, paths), defaults: @settings.call(path).to_h} }
        }
      end

      # Where sessions ran lately, newest first, then every directory whose
      # trust dialog was accepted: the likely choices first. Only an order;
      # the CLI still decides where a session may start.
      def dir_paths
        recent = @store.sessions.sort_by { |s| -s.started_at.to_i }.filter_map { |s| s.cwd && SessionRequest.strip_worktree(s.cwd) }
        (recent + @trust.call).uniq.select { |dir| File.directory?(dir) }
      end

      # Checked cheapest first, and nothing is written to disk until every
      # check has passed. A retry with the same Idempotency-Key gets the
      # first answer instead of a second session; the key sent with a
      # different request is refused, since that answer isn't this one's.
      def post_session(io, request, via)
        params = read_json(io, request)
        key = request.headers["idempotency-key"]
        key = nil if key.to_s.empty?
        digest = OpenSSL::Digest.digest("SHA256", JSON.generate(params)) if key
        images = take_images(params)
        earlier = key && claim(key, digest)
        return json(200, earlier) if earlier
        started = nil
        begin
          started = launch(params, images, via)
          json(201, started)
        ensure
          settle(key, digest, started) if key
        end
      rescue AgentsClient::Error => e
        reason = Http.printable(e.message.lines.first.to_s.strip)
        @queue << [:notice, "remote start failed: #{reason}"]
        @record.call(via, reason)
        raise Http::Error.new(500, e.message, source: "claude")
      rescue Http::Error => e
        @record.call(via, "refused: #{e.message}")
        raise
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
      def claim(key, digest)
        @mutex.synchronize do
          sent, earlier = @keys[key]
          if sent
            raise Http::Error.new(422, "this Idempotency-Key was sent with a different request") unless sent == digest
            raise Http::Error.new(409, "already starting") if earlier == :spawning
            return earlier
          end
          @keys.shift while @keys.size >= KEYS_KEPT
          @keys[key] = [digest, :spawning]
          nil
        end
      end

      # A failed start frees its key, so a retry goes through rather than
      # getting 409 for ever.
      def settle(key, digest, started)
        @mutex.synchronize do
          if started then @keys[key] = [digest, started]
          else @keys.delete(key)
          end
        end
      end

      def launch(params, images, via)
        values = SessionRequest.from_params(params, dirs: dir_paths)
        field, message = SessionRequest.problem(values)
        raise Http::Error.new(422, message, field: field) if field
        defaults = @settings.call(values[:cwd])
        values = SessionRequest.resolve(values, defaults)
        values[:permission_mode] = capped_mode(values[:permission_mode] || defaults.permission_mode || builtin_mode)
        paths = images.each_with_index.map { |bytes, i| Images.save(bytes, dir: @images_dir, index: i + 1) }
        values[:prompt] = SessionRequest.attach(values[:prompt], paths)
        @queue << [:notice, "remote: starting session…"]
        id = Http.utf8(@spawn_lock.synchronize { @client.spawn(**values) })
        url = remote_url(id, wait: values[:remote] ? @bridge_wait : 0)
        @queue << [:remote_started, id, via]
        @record.call(via, "started #{id}")
        {id: id, name: values[:name], cwd: values[:cwd], url: url}
      rescue SessionRequest::Invalid => e
        raise Http::Error.new(422, e.message, field: e.field)
      end

      # Unset, the mode is what the settings files say, so a project defaulting
      # to bypassPermissions can't pass as "default". The spawn always names the
      # mode that passed: the flag beats every settings file short of managed
      # policy, so one the inbox doesn't read can't widen it.
      def capped_mode(mode)
        return mode if @allowed_modes.include?(mode)
        raise Http::Error.new(403, "permission mode #{mode} isn't allowed from another device", field: "permission_mode")
      end

      # Unset in settings, the CLI's own default is auto or manual, never
      # wider. Passed as "default" the CLI takes manual, so auto is named
      # outright wherever it is allowed.
      def builtin_mode = @allowed_modes.include?("auto") ? "auto" : "default"

      # The session registers its bridge a moment after `claude --bg`
      # returns; without it in time the reply has no URL, only the id.
      # Without --remote-control it seldom registers one (docs/cli-quirks.md),
      # so that start looks once rather than waits.
      def remote_url(id, wait:)
        deadline = Http.monotonic + wait
        loop do
          url = Session.new(id: id, job_state: JobState.read(id, jobs_dir: @jobs_dir)).remote_url
          return url if url || Http.monotonic >= deadline
          sleep 0.2
        end
      end
    end
  end
end
