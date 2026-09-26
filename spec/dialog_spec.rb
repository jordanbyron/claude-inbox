# frozen_string_literal: true

require_relative "../lib/claude_inbox/dialog"

RSpec.describe ClaudeInbox::Dialog do
  describe "snooze" do
    let(:dialog) { ClaudeInbox::Dialog::Snooze.new("abc12345") }

    it "answers with the choice behind the key" do
      expect(dialog.press("3", "3")).to eq(:snooze)
      expect(dialog.choice).to eq(:tomorrow_9am)
    end

    it "stays up on a key that is not a choice, and goes on esc or q" do
      expect(dialog.press("x", "x")).to be_nil
      expect(dialog.press(:escape, "\e")).to eq(:cancel)
      expect(dialog.press("q", "q")).to eq(:cancel)
    end

    it "lists every choice in the box" do
      box = dialog.frame(60).join("\n")
      expect(box).to include "Snooze"
      ClaudeInbox::Dialog::Snooze::MENU.each { |k, label, _| expect(box).to include "#{k}  #{label}" }
    end
  end

  describe "confirm" do
    it "asks before pulling a remote session into the daemon" do
      adopt = ClaudeInbox::Dialog::Confirm.new(:adopt, "u1")
      expect(adopt.frame(60).join("\n")).to include "Pull this session into the daemon?"
      expect(adopt.press("y", "y")).to eq(:confirm)
    end

    it "takes y and nothing else, and says which it is asking about" do
      stop = ClaudeInbox::Dialog::Confirm.new(:stop, "abc12345")
      expect(stop.frame(60).join("\n")).to include "Stop session abc12345?"
      expect(stop.press("Y", "Y")).to be_nil
      expect(stop.press("y", "y")).to eq(:confirm)

      delete = ClaudeInbox::Dialog::Confirm.new(:delete, "abc12345")
      expect(delete.frame(60).join("\n")).to include "Delete session abc12345?"
      expect(delete.press("n", "n")).to eq(:cancel)
      expect(delete.press(:escape, "\e")).to eq(:cancel)
    end
  end

  describe "prompt" do
    let(:dialog) { ClaudeInbox::Dialog::Prompt.new(:alias, "abc12345", "auth") }
    let(:caret) { ->(cell) { "[#{cell}]" } }

    it "edits the line and saves it on enter" do
      expect(dialog.press("!", "!")).to be_nil
      expect(dialog.press(:backspace, "\x7f")).to be_nil
      expect(dialog.press(" ", " ")).to be_nil
      expect(dialog.press("x", "x")).to be_nil
      expect(dialog.value).to eq("auth x")
      expect(dialog.press(:enter, "\r")).to eq(:save)
    end

    it "ignores keys that are not printable" do
      dialog.press(:up, "\e[A")
      dialog.press(:tab, "\t")
      expect(dialog.value).to eq("auth")
    end

    it "edits in the middle of the line" do
      dialog.press(:left, "\e[D")
      dialog.press("-", "-")
      expect(dialog.value).to eq("aut-h")
      dialog.press(:ctrl_a, "\x01")
      dialog.press(:delete, "\e[3~")
      expect(dialog.value).to eq("ut-h")
      expect(dialog.frame(60, caret).join("\n")).to include "> [u]t-h"
    end

    it "keeps a space the cursor sits on" do
      dialog.press(:ctrl_w, "\x17")
      dialog.press("a b", "a b")
      dialog.press(:left, "\e[D")
      dialog.press(:left, "\e[D")
      expect(dialog.frame(60, caret).join("\n")).to include "> a[ ]b"
    end

    it "shows the line with a cursor, and its own question per kind" do
      expect(dialog.frame(60, caret).join("\n")).to include "> auth[ ]"
      pr = ClaudeInbox::Dialog::Prompt.new(:pr, "abc12345", "")
      expect(pr.frame(60).join("\n")).to include "Pull request URL (empty clears):"
    end

    it "leaves the string it was given alone" do
      given = "auth"
      ClaudeInbox::Dialog::Prompt.new(:alias, "abc12345", given).press("x", "x")
      expect(given).to eq("auth")
    end
  end
end
