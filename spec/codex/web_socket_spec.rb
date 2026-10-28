# frozen_string_literal: true

require "socket"

RSpec.describe ClaudeInbox::Codex::WebSocket do
  let(:pair) { UNIXSocket.pair }
  let(:ours) { pair[0] }
  let(:theirs) { pair[1] }
  let(:ws) { described_class.new(ours, timeout: 0.5) }
  let(:upgraded) do
    theirs.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n")
    ws.handshake.tap { theirs.read_nonblock(4096) }
  end
  # A frame as the daemon sends it: final, unmasked.
  let(:frame) { ->(op, payload, fin: true) { [(fin ? 0x80 : 0) | op, payload.bytesize].pack("CC") + payload } }
  # What we sent: the first byte, the mask bit and the unmasked payload.
  let(:sent) do
    lambda do
      b0, b1 = theirs.read(2).unpack("CC")
      key = theirs.read(4).bytes
      payload = theirs.read(b1 & 0x7f).bytes.each_with_index.map { |b, i| b ^ key[i % 4] }.pack("C*")
      [b0, b1 & 0x80, payload.force_encoding(Encoding::UTF_8)]
    end
  end

  after { pair.each(&:close) }

  it "asks for the upgrade and refuses anything but 101" do
    theirs.write("HTTP/1.1 400 Bad Request\r\n\r\n")
    expect { ws.handshake }.to raise_error(described_class::Error, /refused: HTTP\/1.1 400/)
    expect(theirs.readpartial(4096)).to match(/\AGET \/ HTTP\/1.1\r\n.*Upgrade: websocket\r\n.*Sec-WebSocket-Version: 13\r\n\r\n\z/m)
  end

  it "sends masked text frames, as a client must" do
    upgraded.write_text("héllo")
    expect(sent.call).to eq([0x81, 0x80, "héllo"])
  end

  it "reads a message split over frames and answers a ping on the way" do
    upgraded
    theirs.write(frame.call(0x9, "hi") + frame.call(0x1, "{\"a\":", fin: false) + frame.call(0x0, "1}"))
    expect(ws.read_text).to eq("{\"a\":1}")
    expect(sent.call).to eq([0x8A, 0x80, "hi"])
  end

  it "gives up on a daemon that closes or goes quiet" do
    upgraded
    theirs.write(frame.call(0x8, ""))
    expect { ws.read_text }.to raise_error(described_class::Error, /closed/)
    expect { ws.read_text }.to raise_error(described_class::Error, /too long/)
  end
end
