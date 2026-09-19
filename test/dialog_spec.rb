# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/claude_inbox/dialog"

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
end
