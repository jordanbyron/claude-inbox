# frozen_string_literal: true

RSpec.describe ClaudeInbox::Remote::PairingDialog do
  subject(:dialog) { described_class.new(-> { snapshot[0] }) }

  let(:token) { "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abcde" }
  let(:listening) do
    ClaudeInbox::Remote::Listener::Snapshot.new(state: :listening, port: 7433, lan: false, urls: ["http://127.0.0.1:7433/##{token}"],
      firewall: nil, allowed_modes: %w[default plan], recent: [], held_by: nil, fixture: false)
  end
  let(:snapshot) { [listening] }

  it "says where it listens, and shows the pairing URL with the token cut short" do
    expect(dialog).to show "listening on 127.0.0.1:7433"
    expect(dialog).to show "http://127.0.0.1:7433/#AbCd…bcde"
    expect(dialog).not_to show token
    expect(dialog).to show "phone may use: default, plan"
    expect(dialog).to show "c copy  r new token  esc close"
  end

  context "in LAN mode" do
    let(:snapshot) { [listening.with(lan: true, firewall: :on, urls: ["http://mac-mini.local:7433/##{token}", "http://192.168.1.20:7433/##{token}"])] }

    it "says LAN mode is cleartext, and lists each address and the firewall" do
      expect(dialog).to show "listening on 0.0.0.0:7433 · LAN, cleartext"
      expect(dialog).to show "http://mac-mini.local:7433/#AbCd…bcde"
      expect(dialog).to show "http://192.168.1.20:7433/#AbCd…bcde"
      expect(dialog).to show "firewall: on"
    end
  end

  it "fills in the addresses from each frame's snapshot once they are known" do
    snapshot[0] = listening.with(urls: nil)
    expect(dialog).to show "looking up this Mac's addresses…"
    snapshot[0] = listening
    expect(dialog).to show "#AbCd…bcde"
  end

  context "while the listener is off" do
    let(:snapshot) { [listening.with(state: :off, urls: nil)] }

    it "says how to turn the listener on while it is off, and then only closes" do
      expect(dialog).to show "off: start with --listen or --listen-lan"
      expect(dialog).to show "esc close"
      expect(dialog.press("c", "c")).to be_nil
      expect(dialog.press("r", "r")).to be_nil
      expect(dialog).not_to show "rotate?"
      expect(dialog.press(:escape, "\e")).to eq(:cancel)
    end
  end

  it "names the inbox that holds the listener, or the port that is taken" do
    snapshot[0] = listening.with(state: :held, held_by: 4242)
    expect(dialog).to show "another inbox (pid 4242) is listening"
    snapshot[0] = listening.with(state: :in_use)
    expect(dialog).to show "127.0.0.1:7433 in use"
    expect(dialog).to show "trying again every few seconds"
    snapshot[0] = listening.with(state: :held, held_by: 4242)
    expect(dialog).to show "this one takes over once that one quits"
  end

  context "once the listener has failed" do
    let(:snapshot) do
      [listening.with(state: :failed, urls: nil, error: "Permission denied @ rb_sysopen - /Users/me/.config/claude-inbox/listen.lock")]
    end

    it "says why the listener failed for good, rather than calling the port taken" do
      lines = dialog.frame(60).map { |l| l.delete("│").strip }
      expect(lines).to include "127.0.0.1:7433: the listener failed"
      expect(lines.join(" ")).to include "Permission denied @ rb_sysopen - /Users/me/.config/claude-inbox/listen.lock"
      expect(lines).to include "restart the inbox once that is fixed"
      expect(lines.join("\n")).not_to include "in use"
      expect(dialog.press("r", "r")).to be_nil
    end
  end

  it "copies on c, and issues a new token only when y answers r" do
    expect(dialog.press("c", "c")).to eq(:copy)
    expect(dialog.press("r", "r")).to be_nil
    expect(dialog).to show "paired phones get 401 until they pair again"
    expect(dialog).to show "rotate? y/n"
    expect(dialog.press("y", "y")).to eq(:rotate)
    expect(dialog).not_to show "rotate?"
    dialog.press("r", "r")
    expect(dialog.press(:escape, "\e")).to be_nil
    expect(dialog).to show "c copy"
    expect(dialog.press("q", "q")).to eq(:cancel)
  end

  context "with outcomes from phones" do
    let(:snapshot) do
      [listening.with(recent: [
        ClaudeInbox::Remote::Listener::Outcome.new(Time.local(2026, 9, 24, 12, 1), "192.168.1.30", "token rejected"),
        ClaudeInbox::Remote::Listener::Outcome.new(Time.local(2026, 9, 24, 12, 3), "192.168.1.30", "started 31472308")
      ])]
    end

    it "lists what phones asked for lately, newest first" do
      lines = dialog.frame(120).map { |l| l.delete("│").strip }
      expect(lines.each_cons(2).find { |a, _| a == "recent:" }&.last).to eq("12:03  192.168.1.30  started 31472308")
      expect(lines).to include "12:01  192.168.1.30  token rejected"
    end
  end

  context "with an outcome that came again" do
    let(:snapshot) do
      [listening.with(recent: [
        ClaudeInbox::Remote::Listener::Outcome.new(at: Time.local(2026, 9, 24, 12, 1), via: "192.168.1.30", result: "token rejected", count: 12)
      ])]
    end

    it "counts an outcome that came again" do
      expect(dialog).to show "12:01  192.168.1.30  token rejected ×12"
    end
  end

  it "is 76 columns at most, and fits a narrow terminal" do
    expect(dialog.frame(200).map { |l| ClaudeInbox::Text.width(l) }.uniq).to eq([76])
    expect(dialog.frame(50).map { |l| ClaudeInbox::Text.width(l) }.uniq).to eq([46])
  end
end
