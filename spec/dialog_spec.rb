# frozen_string_literal: true

RSpec.describe ClaudeInbox::Dialog do
  describe "snooze" do
    let(:dialog) { described_class::Snooze.new("abc12345") }

    it "answers with the choice behind the key" do
      expect(dialog.press("3", "3")).to eq(:snooze)
      expect(dialog.choice).to eq(:tomorrow_9am)
    end

    it "answers 5 with a choice to type, for App to open the prompt" do
      expect(dialog.press("5", "5")).to eq(:snooze)
      expect(dialog.choice).to eq(:custom)
    end

    it "stays up on a key that is not a choice, and goes on esc or q" do
      expect(dialog.press("x", "x")).to be_nil
      expect(dialog.press(:escape, "\e")).to eq(:cancel)
      expect(dialog.press("q", "q")).to eq(:cancel)
    end

    it "lists every choice in the box" do
      box = dialog.frame(60).join("\n")
      expect(box).to include "Snooze"
      described_class::Snooze::MENU.each { |k, label, _| expect(box).to include "#{k}  #{label}" }
    end
  end

  describe "pr picker" do
    let(:prs) do
      [ClaudeInbox::PullRequest.new(number: 189, state: "MERGED"),
        ClaudeInbox::PullRequest.new(number: 190, state: "OPEN", health: "FAILING"),
        ClaudeInbox::PullRequest.new(number: 191)]
    end
    let(:dialog) { described_class::PrPicker.new(:open, session(prs: prs)) }

    it "lists the headline first, then the rest in order" do
      expect(dialog.frame(60).join("\n")).to include(" Open pull request ")
      expect(dialog.lines(40, nil)).to eq(["  1  #190 open · ✗ checks", "  2  #189 merged", "  3  #191",
        "", "  o  open #190 · esc cancel"])
      copy = described_class::PrPicker.new(:copy, session(prs: prs))
      expect(copy.lines(40, nil).last).to eq("  y  copy #190 · esc cancel")
    end

    it "names the repo of each PR once they span repos, and cuts lines to the box" do
      across = [ClaudeInbox::PullRequest.new(number: 1020, url: "https://github.com/jordanbyron/parks_genie/pull/1020",
        state: "OPEN", health: "CHANGES_REQUESTED"),
        ClaudeInbox::PullRequest.new(number: 7, url: "https://github.com/o/r/pull/7")]
      picker = described_class::PrPicker.new(:open, session(prs: across))
      expect(picker.lines(60, nil).first(2)).to eq(["  1  jordanbyron/parks_genie#1020 open · changes requested", "  2  o/r#7"])
      expect(picker.lines(60, nil).last).to eq("  o  open #1020 · esc cancel")
      expect(picker.lines(20, nil).map { |l| ClaudeInbox::Text.width(l) }.max).to eq(20)
      same = [across.first, ClaudeInbox::PullRequest.new(number: 7, url: "https://github.com/jordanbyron/parks_genie/pull/7")]
      expect(described_class::PrPicker.new(:open, session(prs: same)).lines(60, nil)[1]).to eq("  2  #7")
    end

    it "picks the headline on its own key or enter" do
      expect(dialog.press("o", "o")).to eq(:pick)
      expect(dialog.choice.number).to eq(190)
      copy = described_class::PrPicker.new(:copy, session(prs: prs))
      expect(copy.press("o", "o")).to be_nil
      expect(copy.press("y", "y")).to eq(:pick)
      expect(described_class::PrPicker.new(:copy, session(prs: prs)).press(:enter, "\r")).to eq(:pick)
    end

    it "picks the nth on a digit, ignores one past the end, and goes on esc or q" do
      expect(dialog.press("4", "4")).to be_nil
      expect(dialog.press("3", "3")).to eq(:pick)
      expect(dialog.choice.number).to eq(191)
      expect(dialog.press(:escape, "\e")).to eq(:cancel)
      expect(dialog.press("q", "q")).to eq(:cancel)
    end
  end

  describe "confirm" do
    it "asks before pulling a remote session into the daemon" do
      adopt = described_class::Confirm.new(:adopt, "u1")
      expect(adopt.frame(60).join("\n")).to include "Pull this session into the daemon?"
      expect(adopt.press("y", "y")).to eq(:confirm)
    end

    it "offers the Claude Code pane and says how to add it later" do
      install = described_class::PaneOffer.new
      expect(install.frame(80).join("\n")).to include "later with claude-inbox install"
      expect(install.press("y", "y")).to eq(:confirm)
    end

    it "takes y and nothing else, and says which it is asking about" do
      stop = described_class::Confirm.new(:stop, "abc12345")
      expect(stop.frame(60).join("\n")).to include "Stop session abc12345?"
      expect(stop.press("Y", "Y")).to be_nil
      expect(stop.press("y", "y")).to eq(:confirm)

      delete = described_class::Confirm.new(:delete, "abc12345")
      expect(delete.frame(60).join("\n")).to include "Delete session abc12345?"
      expect(delete.press("n", "n")).to eq(:cancel)
      expect(delete.press(:escape, "\e")).to eq(:cancel)
    end
  end

  describe "prompt" do
    let(:dialog) { described_class::Prompt.new(:alias, "abc12345", "auth") }
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
      pr = described_class::Prompt.new(:pr, "abc12345", "")
      expect(pr.frame(60).join("\n")).to include "Pull request URL (empty clears):"
      snooze = described_class::Prompt.new(:snooze, "abc12345", "")
      expect(snooze.frame(60).join("\n")).to include "Wake at (2h, 5pm, fri, tonight):"
    end

    it "leaves the string it was given alone" do
      given = "auth"
      described_class::Prompt.new(:alias, "abc12345", given).press("x", "x")
      expect(given).to eq("auth")
    end
  end
end
