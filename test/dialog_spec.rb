# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/claude_inbox/dialog"
require_relative "../lib/claude_inbox/listener"

describe ClaudeInbox::Dialog do
  describe "snooze" do
    let(:dialog) { ClaudeInbox::Dialog::Snooze.new("abc12345") }

    it "answers with the choice behind the key" do
      _(dialog.press("3", "3")).must_equal :snooze
      _(dialog.choice).must_equal :tomorrow_9am
    end

    it "stays up on a key that is not a choice, and goes on esc or q" do
      _(dialog.press("x", "x")).must_be_nil
      _(dialog.press(:escape, "\e")).must_equal :cancel
      _(dialog.press("q", "q")).must_equal :cancel
    end

    it "lists every choice in the box" do
      box = dialog.frame(60).join("\n")
      _(box).must_include "Snooze"
      ClaudeInbox::Dialog::Snooze::MENU.each { |k, label, _| _(box).must_include "#{k}  #{label}" }
    end
  end

  describe "confirm" do
    it "asks before pulling a remote session into the daemon" do
      adopt = ClaudeInbox::Dialog::Confirm.new(:adopt, "u1")
      _(adopt.frame(60).join("\n")).must_include "Pull this session into the daemon?"
      _(adopt.press("y", "y")).must_equal :confirm
    end

    it "takes y and nothing else, and says which it is asking about" do
      stop = ClaudeInbox::Dialog::Confirm.new(:stop, "abc12345")
      _(stop.frame(60).join("\n")).must_include "Stop session abc12345?"
      _(stop.press("Y", "Y")).must_be_nil
      _(stop.press("y", "y")).must_equal :confirm

      delete = ClaudeInbox::Dialog::Confirm.new(:delete, "abc12345")
      _(delete.frame(60).join("\n")).must_include "Delete session abc12345?"
      _(delete.press("n", "n")).must_equal :cancel
      _(delete.press(:escape, "\e")).must_equal :cancel
    end
  end

  describe "prompt" do
    let(:dialog) { ClaudeInbox::Dialog::Prompt.new(:alias, "abc12345", "auth") }
    let(:caret) { ->(cell) { "[#{cell}]" } }

    it "edits the line and saves it on enter" do
      _(dialog.press("!", "!")).must_be_nil
      _(dialog.press(:backspace, "\x7f")).must_be_nil
      _(dialog.press(" ", " ")).must_be_nil
      _(dialog.press("x", "x")).must_be_nil
      _(dialog.value).must_equal "auth x"
      _(dialog.press(:enter, "\r")).must_equal :save
    end

    it "ignores keys that are not printable" do
      dialog.press(:up, "\e[A")
      dialog.press(:tab, "\t")
      _(dialog.value).must_equal "auth"
    end

    it "edits in the middle of the line" do
      dialog.press(:left, "\e[D")
      dialog.press("-", "-")
      _(dialog.value).must_equal "aut-h"
      dialog.press(:ctrl_a, "\x01")
      dialog.press(:delete, "\e[3~")
      _(dialog.value).must_equal "ut-h"
      _(dialog.frame(60, caret).join("\n")).must_include "> [u]t-h"
    end

    it "keeps a space the cursor sits on" do
      dialog.press(:ctrl_w, "\x17")
      dialog.press("a b", "a b")
      dialog.press(:left, "\e[D")
      dialog.press(:left, "\e[D")
      _(dialog.frame(60, caret).join("\n")).must_include "> a[ ]b"
    end

    it "shows the line with a cursor, and its own question per kind" do
      _(dialog.frame(60, caret).join("\n")).must_include "> auth[ ]"
      pr = ClaudeInbox::Dialog::Prompt.new(:pr, "abc12345", "")
      _(pr.frame(60).join("\n")).must_include "Pull request URL (empty clears):"
    end

    it "leaves the string it was given alone" do
      given = "auth"
      ClaudeInbox::Dialog::Prompt.new(:alias, "abc12345", given).press("x", "x")
      _(given).must_equal "auth"
    end
  end

  describe "pairing" do
    let(:token) { "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abcde" }
    let(:listening) do
      ClaudeInbox::Listener::Snapshot.new(state: :listening, port: 7433, lan: false, urls: ["http://127.0.0.1:7433/##{token}"],
        firewall: nil, allowed_modes: %w[default plan], recent: [], held_by: nil, fixture: false)
    end
    let(:snapshot) { [listening] }
    let(:dialog) { ClaudeInbox::Dialog::Pairing.new(-> { snapshot[0] }) }

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
        ClaudeInbox::Listener::Outcome.new(Time.local(2026, 9, 24, 12, 1), "192.168.1.30", "token rejected"),
        ClaudeInbox::Listener::Outcome.new(Time.local(2026, 9, 24, 12, 3), "192.168.1.30", "started 31472308")
      ])
      lines = dialog.frame(120).map { |l| l.delete("│").strip }
      _(lines.each_cons(2).find { |a, _| a == "recent:" }&.last).must_equal "12:03  192.168.1.30  started 31472308"
      _(lines).must_include "12:01  192.168.1.30  token rejected"
    end

    it "counts an outcome that came again" do
      snapshot[0] = listening.with(recent: [
        ClaudeInbox::Listener::Outcome.new(at: Time.local(2026, 9, 24, 12, 1), via: "192.168.1.30", result: "token rejected", count: 12)
      ])
      _(box).must_include "12:01  192.168.1.30  token rejected ×12"
    end

    it "is 76 columns at most, and fits a narrow terminal" do
      _(dialog.frame(200).map { |l| ClaudeInbox::Text.width(l) }.uniq).must_equal [76]
      _(dialog.frame(50).map { |l| ClaudeInbox::Text.width(l) }.uniq).must_equal [46]
    end
  end
end
