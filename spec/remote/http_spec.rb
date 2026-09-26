# frozen_string_literal: true

require "socket"

RSpec.describe ClaudeInbox::Remote::Http, :http_head do
  let(:deadline) { described_class.monotonic + 5 }

  describe "reading a request head" do
    it "splits the request line and keys the headers in lower case" do
      request = head("POST /api/sessions?x=1 HTTP/1.1\r\nHost: 127.0.0.1:7433\r\nContent-Type:  application/json \r\n\r\n")
      expect(request.verb).to eq("POST")
      expect(request.path).to eq("/api/sessions")
      expect(request.query).to eq("x=1")
      expect(request.version).to eq("1.1")
      expect(request.headers).to eq({"host" => "127.0.0.1:7433", "content-type" => "application/json"})
    end

    it "takes a bare newline as a line end" do
      expect(head("GET / HTTP/1.0\nHost: x\n\n").headers).to eq({"host" => "x"})
    end

    it "joins a repeated header, so a second Content-Length can't pass for the first" do
      request = head("POST / HTTP/1.1\r\nContent-Length: 5\r\ncontent-length: 50\r\n\r\n")
      expect(request.headers["content-length"]).to eq("5, 50")
      expect { request.read_body(StringIO.new, max: 100, deadline: deadline) }.to be_http_refused_with(400)
    end

    it "refuses a line over 8 KiB, more than 64 headers, and anything that isn't HTTP/1.x" do
      expect { head("GET /#{"a" * 9000} HTTP/1.1\r\n\r\n") }.to be_http_refused_with(400)
      expect { head("GET / HTTP/1.1\r\nX-Long: #{"a" * 9000}\r\n\r\n") }.to be_http_refused_with(400)
      expect { head("GET / HTTP/1.1\r\nX-Long: #{"a" * 70_000}") }.to be_http_refused_with(400)
      expect(head("GET / HTTP/1.1\r\nX-Long: #{"a" * (8192 - 9)}\r\n\r\n").headers["x-long"].bytesize).to eq(8183)
      expect { head("GET / HTTP/1.1\r\nX-Long: #{"a" * (8192 - 8)}\r\n\r\n") }.to be_http_refused_with(400)
      expect { head("GET / HTTP/1.1\r\n" + "X-A: 1\r\n" * 65 + "\r\n") }.to be_http_refused_with(400)
      expect(head("GET / HTTP/1.1\r\n" + "X-A: 1\r\n" * 64 + "\r\n").headers["x-a"]).to match(/\A1(, 1){63}\z/)
      expect { head("HELLO\r\n\r\n") }.to be_http_refused_with(400)
      expect { head("GET / HTTP/2.0\r\n\r\n") }.to be_http_refused_with(400)
      expect { head("GET / HTTP/1.1\r\nno colon here\r\n\r\n") }.to be_http_refused_with(400)
      expect { head("GET / HTTP/1.1\r\nHost: x") }.to be_http_refused_with(400)
    end

    # One byte every 20ms would satisfy any per-read timeout for ever.
    it "gives the whole head one deadline, however steadily the bytes come" do
      reader, writer = IO.pipe
      trickle = Thread.new do
        ("GET / HTTP/1.1\r\n" + "X: y\r\n" * 20).each_char do |c|
          writer.write(c)
          sleep 0.02
        end
      end
      started = described_class.monotonic
      expect { described_class.read_head(reader, deadline: described_class.monotonic + 0.2) }.to raise_error(described_class::Error) { |error|
        expect(error.status).to eq(400)
        expect(error.message).to include "too long"
      }
      expect(described_class.monotonic - started).to be < 1
    ensure
      trickle.kill
      reader.close
      writer.close
    end
  end

  describe "reading the body" do
    it "reads what came with the head and what follows it, up to Content-Length" do
      reader, writer = IO.pipe
      writer.write("POST / HTTP/1.1\r\nContent-Length: 11\r\n\r\nhello")
      request = described_class.read_head(reader, deadline: deadline)
      later = Thread.new do
        sleep 0.05
        writer.write(" world, and more")
      end
      expect(request.read_body(reader, max: 100, deadline: deadline)).to eq("hello world")
      later.join
    ensure
      reader.close
      writer.close
    end

    it "answers Expect: 100-continue before reading a body the client is holding back" do
      server, client = UNIXSocket.pair
      client.write("POST / HTTP/1.1\r\nContent-Length: 5\r\nExpect: 100-continue\r\n\r\n")
      request = described_class.read_head(server, deadline: deadline)
      body = Thread.new { request.read_body(server, max: 10, deadline: deadline) }
      expect(client.readpartial(100)).to eq("HTTP/1.1 100 Continue\r\n\r\n")
      client.write("hello")
      expect(body.value).to eq("hello")
    ensure
      server.close
      client.close
    end

    it "wants a Content-Length within the limit, and nothing chunked" do
      expect { head("POST / HTTP/1.1\r\n\r\n").read_body(StringIO.new, max: 10, deadline: deadline) }.to be_http_refused_with(411)
      expect { head("POST / HTTP/1.1\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n").read_body(StringIO.new, max: 10, deadline: deadline) }.to be_http_refused_with(400)
      expect { head("POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n").read_body(StringIO.new, max: 10, deadline: deadline) }.to be_http_refused_with(400)
      out = StringIO.new
      expect { head("POST / HTTP/1.1\r\nContent-Length: 11\r\nExpect: 100-continue\r\n\r\n").read_body(out, max: 10, deadline: deadline) }.to be_http_refused_with(413)
      expect(out.string).to be_empty
    end
  end

  describe "writing a response" do
    it "carries the length and the headers every response gets" do
      out = StringIO.new
      described_class.write(out, 201, {"Content-Type" => "application/json"}, "{\"a\":\"é\"}")
      expect(out.string.b).to eq("HTTP/1.1 201 Created\r\nConnection: close\r\nCache-Control: no-store\r\n" \
        "X-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Type: application/json\r\n" \
        "Content-Length: 10\r\n\r\n{\"a\":\"é\"}".b)
    end
  end

  it "makes an error's body valid UTF-8, whatever bytes its message quotes" do
    body = described_class::Error.new(500, "claude --bg failed: caf\xC3\xA9 \xFF".b, field: :cwd, index: 2).body
    expect(body).to eq({error: "claude --bg failed: café �", field: "cwd", index: 2})
    expect(body[:error].encoding).to eq Encoding::UTF_8
  end
end
