# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/claude_inbox/remote/listener"

describe ClaudeInbox::Remote::PairingDialog do
  let(:token) { "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abcde" }
  let(:listening) do
    ClaudeInbox::Remote::Listener::Snapshot.new(state: :listening, port: 7433, lan: false, urls: ["http://127.0.0.1:7433/##{token}"],
      firewall: nil, allowed_modes: %w[default plan], recent: [], held_by: nil, fixture: false)
  end
  let(:snapshot) { [listening] }
  let(:dialog) { ClaudeInbox::Remote::PairingDialog.new(-> { snapshot[0] }) }

  def box(width = 120) = dialog.frame(width).join("\n")

  it "says where it listens, and shows the pairing URL with the token cut short" do
    _(box).must_include "listening on 127.0.0.1:7433"
    _(box).must_include "http://127.0.0.1:7433/#AbCd…bcde"
    _(box).wont_include token
    _(box).must_include "phone may use: default, plan"
    _(box).must_include "c copy  r new token  esc close"
  end

  it "says LAN mode is cleartext, and lists each address and the firewall" do
    snapshot[0] = listening.with(lan: true, firewall: :on, urls: ["http://mac-mini.local:7433/##{token}", "http://192.168.1.20:7433/##{token}"])
    _(box).must_include "listening on 0.0.0.0:7433 · LAN, cleartext"
    _(box).must_include "http://mac-mini.local:7433/#AbCd…bcde"
    _(box).must_include "http://192.168.1.20:7433/#AbCd…bcde"
    _(box).must_include "firewall: on"
  end

  it "fills in the addresses from each frame's snapshot once they are known" do
    snapshot[0] = listening.with(urls: nil)
    _(box).must_include "looking up this Mac's addresses…"
    snapshot[0] = listening
    _(box).must_include "#AbCd…bcde"
  end

  it "says how to turn the listener on while it is off, and then only closes" do
    snapshot[0] = listening.with(state: :off, urls: nil)
    _(box).must_include "off: start with --listen or --listen-lan"
    _(box).must_include "esc close"
    _(dialog.press("c", "c")).must_be_nil
    _(dialog.press("r", "r")).must_be_nil
    _(box).wont_include "rotate?"
    _(dialog.press(:escape, "\e")).must_equal :cancel
  end

  it "names the inbox that holds the listener, or the port that is taken" do
    snapshot[0] = listening.with(state: :held, held_by: 4242)
    _(box).must_include "another inbox (pid 4242) is listening"
    snapshot[0] = listening.with(state: :in_use)
    _(box).must_include "127.0.0.1:7433 in use"
    _(box).must_include "trying again every few seconds"
    snapshot[0] = listening.with(state: :held, held_by: 4242)
    _(box).must_include "this one takes over once that one quits"
  end

  it "says why the listener failed for good, rather than calling the port taken" do
    snapshot[0] = listening.with(state: :failed, urls: nil,
      error: "Permission denied @ rb_sysopen - /Users/me/.config/claude-inbox/listen.lock")
    lines = dialog.frame(60).map { |l| l.delete("│").strip }
    _(lines).must_include "127.0.0.1:7433: the listener failed"
    _(lines.join(" ")).must_include "Permission denied @ rb_sysopen - /Users/me/.config/claude-inbox/listen.lock"
    _(lines).must_include "restart the inbox once that is fixed"
    _(lines.join("\n")).wont_include "in use"
    _(dialog.press("r", "r")).must_be_nil
  end

  it "copies on c, and issues a new token only when y answers r" do
    _(dialog.press("c", "c")).must_equal :copy
    _(dialog.press("r", "r")).must_be_nil
    _(box).must_include "paired phones get 401 until they pair again"
    _(box).must_include "rotate? y/n"
    _(dialog.press("y", "y")).must_equal :rotate
    _(box).wont_include "rotate?"
    dialog.press("r", "r")
    _(dialog.press(:escape, "\e")).must_be_nil
    _(box).must_include "c copy"
    _(dialog.press("q", "q")).must_equal :cancel
  end

  it "lists what phones asked for lately, newest first" do
    snapshot[0] = listening.with(recent: [
      ClaudeInbox::Remote::Listener::Outcome.new(Time.local(2026, 9, 24, 12, 1), "192.168.1.30", "token rejected"),
      ClaudeInbox::Remote::Listener::Outcome.new(Time.local(2026, 9, 24, 12, 3), "192.168.1.30", "started 31472308")
    ])
    lines = dialog.frame(120).map { |l| l.delete("│").strip }
    _(lines.each_cons(2).find { |a, _| a == "recent:" }&.last).must_equal "12:03  192.168.1.30  started 31472308"
    _(lines).must_include "12:01  192.168.1.30  token rejected"
  end

  it "counts an outcome that came again" do
    snapshot[0] = listening.with(recent: [
      ClaudeInbox::Remote::Listener::Outcome.new(at: Time.local(2026, 9, 24, 12, 1), via: "192.168.1.30", result: "token rejected", count: 12)
    ])
    _(box).must_include "12:01  192.168.1.30  token rejected ×12"
  end

  it "is 76 columns at most, and fits a narrow terminal" do
    _(dialog.frame(200).map { |l| ClaudeInbox::Text.width(l) }.uniq).must_equal [76]
    _(dialog.frame(50).map { |l| ClaudeInbox::Text.width(l) }.uniq).must_equal [46]
  end
end
