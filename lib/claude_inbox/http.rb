# frozen_string_literal: true

module ClaudeInbox
  # The little of HTTP/1.1 the listener speaks: one request per
  # connection, a body sized by Content-Length, and a response that closes
  # the connection. Nothing here knows a route or a token.
  module Http
    MAX_LINE = 8 * 1024
    MAX_HEADERS = 64
    CHUNK = 64 * 1024
    TOKEN = /\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/

    REASONS = {
      100 => "Continue", 200 => "OK", 201 => "Created", 400 => "Bad Request", 401 => "Unauthorized",
      403 => "Forbidden", 404 => "Not Found", 405 => "Method Not Allowed", 409 => "Conflict",
      411 => "Length Required", 413 => "Content Too Large", 415 => "Unsupported Media Type",
      421 => "Misdirected Request", 422 => "Unprocessable Content", 500 => "Internal Server Error",
      503 => "Service Unavailable"
    }.freeze

    HEADERS = {
      "Connection" => "close",
      "Cache-Control" => "no-store",
      "X-Content-Type-Options" => "nosniff",
      "Referrer-Policy" => "no-referrer"
    }.freeze

    # A request refused: the status, the message and any other members for
    # the JSON body, and the headers that status calls for.
    class Error < StandardError
      attr_reader :status, :headers, :details

      def initialize(status, message, headers: {}, **details)
        super(message)
        @status = status
        @headers = headers
        @details = details
      end

      def body = {error: Http.utf8(message), **details.transform_values { |v| v.is_a?(Integer) ? v : Http.utf8(v) }}
    end

    # A request head. `headers` are keyed in lower case, and a repeated
    # header is joined with ", ", so a second Content-Length or Host can't
    # pass for the first. The bytes read past the head stay here for the
    # body.
    class Request
      attr_reader :verb, :path, :query, :version, :headers

      def initialize(verb, target, version, headers, rest)
        @verb = verb
        @path, @query = target.split("?", 2)
        @version = version
        @headers = headers
        @rest = rest
      end

      # Read only once the request has earned it: a client that sent
      # `Expect: 100-continue` holds the body back until it hears 100.
      def read_body(io, max:, deadline:)
        raise Error.new(400, "Transfer-Encoding isn't accepted; send Content-Length") if headers.key?("transfer-encoding")
        length = headers["content-length"]
        raise Error.new(411, "Content-Length is required") unless length
        raise Error.new(400, "Content-Length isn't a number") unless length.match?(/\A\d{1,15}\z/)
        size = length.to_i
        raise Error.new(413, "the body is over #{max} bytes") if size > max
        io.write("HTTP/1.1 100 Continue\r\n\r\n") if headers["expect"]&.casecmp?("100-continue") && @rest.bytesize < size
        Http.fill(io, @rest, deadline) while @rest.bytesize < size
        @rest.byteslice(0, size)
      end
    end

    def self.monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # The JSON generator warns on stderr, which is the terminal, about a
    # binary string and raises on a bad byte, and a message can quote CLI
    # output or request bytes.
    def self.utf8(text) = String.new(text.to_s, encoding: Encoding::UTF_8).scrub("\uFFFD")

    # `deadline` (on the monotonic clock) bounds the whole head, not each
    # read: a per-read timeout lets a byte every few seconds hold the
    # connection for ever.
    def self.read_head(io, deadline:)
      rest = +"".b
      line = read_line(io, rest, deadline)
      request = line.match(%r{\A(\S+) (/\S*) HTTP/(1\.[01])\z})
      raise Error.new(400, "not an HTTP/1.x request line") unless request && request[1].match?(TOKEN)
      headers = {}
      count = 0
      loop do
        line = read_line(io, rest, deadline)
        return Request.new(request[1], request[2], request[3], headers, rest) if line.empty?
        raise Error.new(400, "more than #{MAX_HEADERS} headers") if (count += 1) > MAX_HEADERS
        name, value = line.split(":", 2)
        raise Error.new(400, "malformed header") unless value && name.match?(TOKEN)
        key = name.downcase
        value = value.strip
        headers[key] = headers.key?(key) ? "#{headers[key]}, #{value}" : value
      end
    end

    def self.write(io, status, headers = {}, body = "")
      body = body.b
      head = ["HTTP/1.1 #{status} #{REASONS.fetch(status)}"]
      HEADERS.merge(headers, "Content-Length" => body.bytesize.to_s).each { |name, value| head << "#{name}: #{value}" }
      io.write((head.join("\r\n") + "\r\n\r\n").b + body)
    end

    def self.read_line(io, rest, deadline)
      until (i = rest.index("\n"))
        raise Error.new(400, "a line of the request head is over #{MAX_LINE} bytes") if rest.bytesize > MAX_LINE
        fill(io, rest, deadline)
      end
      raise Error.new(400, "a line of the request head is over #{MAX_LINE} bytes") if i > MAX_LINE
      rest.slice!(0..i).chomp
    end

    def self.fill(io, rest, deadline)
      loop do
        case (chunk = io.read_nonblock(CHUNK, exception: false))
        when nil then raise Error.new(400, "the connection closed mid-request")
        when :wait_readable
          left = deadline - monotonic
          raise Error.new(400, "the request took too long") unless left > 0 && IO.select([io], nil, nil, left)
        else return rest << chunk
        end
      end
    end
    private_class_method :read_line
  end
end
