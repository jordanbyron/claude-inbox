# frozen_string_literal: true

require_relative "test_helper"

describe ClaudeInbox::Keymap do
  let(:t) { [Time.at(0)] }
  let(:km) { ClaudeInbox::Keymap.new(clock: -> { t[0] }) }

  it "maps vim motion keys and arrows alike" do
    _(km.press("j", "j")).must_equal :down
    _(km.press(:down, "\e[B")).must_equal :down
    _(km.press("k", "k")).must_equal :up
    _(km.press("G", "G")).must_equal :bottom
    _(km.press(:ctrl_d, "\x04")).must_equal :half_page_down
    _(km.press(:ctrl_u, "\x15")).must_equal :half_page_up
  end

  it "resolves gg as a chord" do
    _(km.press("g", "g")).must_be_nil
    _(km.pending).must_equal "g"
    _(km.press("g", "g")).must_equal :top
    _(km.pending).must_be_nil
  end

  it "drops a chord on an unknown second key" do
    km.press("g", "g")
    _(km.press("x", "x")).must_be_nil
    _(km.press("x", "x")).must_equal :settle
  end

  it "expires a pending chord after the timeout" do
    km.press("g", "g")
    t[0] += ClaudeInbox::Keymap::CHORD_TIMEOUT + 0.1
    _(km.press("g", "g")).must_be_nil
    _(km.pending).must_equal "g"
  end

  it "folds with z chords" do
    %w[o c a].zip(%i[fold_open fold_close fold_toggle]).each do |k, action|
      km.press("z", "z")
      _(km.press(k, k)).must_equal action
    end
  end

  it "maps actions" do
    _(km.press(:return, "\r")).must_equal :activate
    _(km.press("l", "l")).must_equal :activate
    _(km.press("h", "h")).must_equal :collapse
    _(km.press("s", "s")).must_equal :snooze
    _(km.press("u", "u")).must_equal :wake
    _(km.press("a", "a")).must_equal :alias
    _(km.press("x", "x")).must_equal :settle
    _(km.press("X", "X")).must_equal :stop
    _(km.press(:ctrl_x, "\x18")).must_equal :delete
    _(km.press("p", "p")).must_equal :toggle_peek
    _(km.press("n", "n")).must_equal :new_session
    _(km.press("t", "t")).must_equal :toggle_pin
    _(km.press("o", "o")).must_equal :open_pr
    _(km.press("P", "P")).must_equal :link_pr
    _(km.press(:tab, "\t")).must_equal :next_section
    _(km.press(:back_tab, "\e[Z")).must_equal :prev_section
    _(km.press("/", "/")).must_equal :filter
    _(km.press(":", ":")).must_equal :command
    _(km.press("q", "q")).must_equal :quit
    _(km.press(:ctrl_c, "\x03")).must_equal :quit
  end

  it "scrolls the peek pane with J/K and ^e/^y" do
    _(km.press("J", "J")).must_equal :peek_down
    _(km.press("K", "K")).must_equal :peek_up
    _(km.press(:ctrl_e, "\x05")).must_equal :peek_down
    _(km.press(:ctrl_y, "\x19")).must_equal :peek_up
  end

  it "understands ex commands" do
    _(ClaudeInbox::Keymap.command("q")).must_equal :quit
    _(ClaudeInbox::Keymap.command(" wq ")).must_equal :quit
    _(ClaudeInbox::Keymap.command("peek")).must_equal :toggle_peek
    _(ClaudeInbox::Keymap.command("new")).must_equal :new_session
    _(ClaudeInbox::Keymap.command("pr")).must_equal :open_pr
    _(ClaudeInbox::Keymap.command("pin")).must_equal :toggle_pin
    _(ClaudeInbox::Keymap.command("nope")).must_be_nil
  end
end
