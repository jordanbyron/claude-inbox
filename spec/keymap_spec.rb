# frozen_string_literal: true

RSpec.describe ClaudeInbox::Keymap do
  let(:t) { [Time.at(0)] }
  subject(:km) { described_class.new(clock: -> { t[0] }) }

  it "maps vim motion keys and arrows alike" do
    expect(km.press("j", "j")).to eq(:down)
    expect(km.press(:down, "\e[B")).to eq(:down)
    expect(km.press("k", "k")).to eq(:up)
    expect(km.press("G", "G")).to eq(:bottom)
    expect(km.press(:ctrl_d, "\x04")).to eq(:half_page_down)
    expect(km.press(:ctrl_u, "\x15")).to eq(:half_page_up)
  end

  it "resolves gg as a chord" do
    expect(km.press("g", "g")).to be_nil
    expect(km.pending).to eq("g")
    expect(km.press("g", "g")).to eq(:top)
    expect(km.pending).to be_nil
  end

  it "drops a chord on an unknown second key" do
    km.press("g", "g")
    expect(km.press("x", "x")).to be_nil
    expect(km.press("x", "x")).to eq(:settle)
  end

  it "expires a pending chord after the timeout" do
    km.press("g", "g")
    t[0] += described_class::CHORD_TIMEOUT + 0.1
    expect(km.press("g", "g")).to be_nil
    expect(km.pending).to eq("g")
  end

  it "folds with z chords" do
    %w[o c a].zip(%i[fold_open fold_close fold_toggle]).each do |k, action|
      km.press("z", "z")
      expect(km.press(k, k)).to eq(action)
    end
  end

  it "maps actions" do
    expect(km.press(:return, "\r")).to eq(:activate)
    expect(km.press("l", "l")).to eq(:activate)
    expect(km.press("h", "h")).to eq(:collapse)
    expect(km.press("s", "s")).to eq(:snooze)
    expect(km.press("u", "u")).to eq(:wake)
    expect(km.press("a", "a")).to eq(:alias)
    expect(km.press("x", "x")).to eq(:settle)
    expect(km.press("X", "X")).to eq(:stop)
    expect(km.press(:ctrl_x, "\x18")).to eq(:delete)
    expect(km.press("p", "p")).to eq(:toggle_peek)
    expect(km.press("n", "n")).to eq(:new_session)
    expect(km.press("N", "N")).to eq(:remote_pairing)
    expect(km.press("t", "t")).to eq(:toggle_pin)
    expect(km.press("o", "o")).to eq(:open_pr)
    expect(km.press("w", "w")).to eq(:open_remote)
    expect(km.press("P", "P")).to eq(:link_pr)
    expect(km.press(:tab, "\t")).to eq(:next_section)
    expect(km.press(:back_tab, "\e[Z")).to eq(:prev_section)
    expect(km.press("/", "/")).to eq(:filter)
    expect(km.press("q", "q")).to eq(:quit)
    expect(km.press(:ctrl_c, "\x03")).to eq(:quit)
  end

  it "scrolls the peek pane with J/K and ^e/^y" do
    expect(km.press("J", "J")).to eq(:peek_down)
    expect(km.press("K", "K")).to eq(:peek_up)
    expect(km.press(:ctrl_e, "\x05")).to eq(:peek_down)
    expect(km.press(:ctrl_y, "\x19")).to eq(:peek_up)
  end
end
