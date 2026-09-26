# frozen_string_literal: true

require_relative "../../lib/claude_inbox/remote/listener"

RSpec.describe ClaudeInbox::Remote::PairingDialog do
  let(:token) { "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abcde" }
  let(:listening) do
    ClaudeInbox::Remote::Listener::Snapshot.new(state: :listening, port: 7433, lan: false, urls: ["http://127.0.0.1:7433/##{token}"],
      firewall: nil, allowed_modes: %w[default plan], recent: [], held_by: nil, fixture: false)
  end
  let(:snapshot) { [listening] }
  let(:dialog) { ClaudeInbox::Remote::PairingDialog.new(-> { snapshot[0] }) }

  def box(width = 120) = dialog.frame(width).join("\n")

  it "says where it listens, and shows the pairing URL with the token cut short" do
    expect(box).to include "listening on 127.0.0.1:7433"
    expect(box).to include "http://127.0.0.1:7433/#AbCd…bcde"
    expect(box).not_to include token
    expect(box).to include "phone may use: default, plan"
    expect(box).to include "c copy  r new token  esc close"
  end

  it "says LAN mode is cleartext, and lists each address and the firewall" do
    snapshot[0] = listening.with(lan: true, firewall: :on, urls: ["http://mac-mini.local:7433/##{token}", "http://192.168.1.20:7433/##{token}"])
    expect(box).to include "listening on 0.0.0.0:7433 · LAN, cleartext"
    expect(box).to include "http://mac-mini.local:7433/#AbCd…bcde"
    expect(box).to include "http://192.168.1.20:7433/#AbCd…bcde"
    expect(box).to include "firewall: on"
  end

  it "fills in the addresses from each frame's snapshot once they are known" do
    snapshot[0] = listening.with(urls: nil)
    expect(box).to include "looking up this Mac's addresses…"
    snapshot[0] = listening
    expect(box).to include "#AbCd…bcde"
  end

  it "says how to turn the listener on while it is off, and then only closes" do
    snapshot[0] = listening.with(state: :off, urls: nil)
    expect(box).to include "off: start with --listen or --listen-lan"
    expect(box).to include "esc close"
    expect(dialog.press("c", "c")).to be_nil
    expect(dialog.press("r", "r")).to be_nil
    expect(box).not_to include "rotate?"
    expect(dialog.press(:escape, "\e")).to eq(:cancel)
  end

  it "names the inbox that holds the listener, or the port that is taken" do
    snapshot[0] = listening.with(state: :held, held_by: 4242)
    expect(box).to include "another inbox (pid 4242) is listening"
    snapshot[0] = listening.with(state: :in_use)
    expect(box).to include "127.0.0.1:7433 in use"
    expect(box).to include "trying again every few seconds"
    snapshot[0] = listening.with(state: :held, held_by: 4242)
    expect(box).to include "this one takes over once that one quits"
  end

  it "says why the listener failed for good, rather than calling the port taken" do
    snapshot[0] = listening.with(state: :failed, urls: nil,
      error: "Permission denied @ rb_sysopen - /Users/me/.config/claude-inbox/listen.lock")
    lines = dialog.frame(60).map { |l| l.delete("│").strip }
    expect(lines).to include "127.0.0.1:7433: the listener failed"
    expect(lines.join(" ")).to include "Permission denied @ rb_sysopen - /Users/me/.config/claude-inbox/listen.lock"
    expect(lines).to include "restart the inbox once that is fixed"
    expect(lines.join("\n")).not_to include "in use"
    expect(dialog.press("r", "r")).to be_nil
  end

  it "copies on c, and issues a new token only when y answers r" do
    expect(dialog.press("c", "c")).to eq(:copy)
    expect(dialog.press("r", "r")).to be_nil
    expect(box).to include "paired phones get 401 until they pair again"
    expect(box).to include "rotate? y/n"
    expect(dialog.press("y", "y")).to eq(:rotate)
    expect(box).not_to include "rotate?"
    dialog.press("r", "r")
    expect(dialog.press(:escape, "\e")).to be_nil
    expect(box).to include "c copy"
    expect(dialog.press("q", "q")).to eq(:cancel)
  end

  it "lists what phones asked for lately, newest first" do
    snapshot[0] = listening.with(recent: [
      ClaudeInbox::Remote::Listener::Outcome.new(Time.local(2026, 9, 24, 12, 1), "192.168.1.30", "token rejected"),
      ClaudeInbox::Remote::Listener::Outcome.new(Time.local(2026, 9, 24, 12, 3), "192.168.1.30", "started 31472308")
    ])
    lines = dialog.frame(120).map { |l| l.delete("│").strip }
    expect(lines.each_cons(2).find { |a, _| a == "recent:" }&.last).to eq("12:03  192.168.1.30  started 31472308")
    expect(lines).to include "12:01  192.168.1.30  token rejected"
  end

  it "counts an outcome that came again" do
    snapshot[0] = listening.with(recent: [
      ClaudeInbox::Remote::Listener::Outcome.new(at: Time.local(2026, 9, 24, 12, 1), via: "192.168.1.30", result: "token rejected", count: 12)
    ])
    expect(box).to include "12:01  192.168.1.30  token rejected ×12"
  end

  it "is 76 columns at most, and fits a narrow terminal" do
    expect(dialog.frame(200).map { |l| ClaudeInbox::Text.width(l) }.uniq).to eq([76])
    expect(dialog.frame(50).map { |l| ClaudeInbox::Text.width(l) }.uniq).to eq([46])
  end
end
