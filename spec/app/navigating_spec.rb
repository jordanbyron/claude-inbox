# frozen_string_literal: true

RSpec.describe ClaudeInbox::App do
  let(:terminal) { ScreenTerminal.new }

  let(:client) { RecordingClient.new }
  let(:store) { ClaudeInbox::Store.new(path: nil) }
  let(:pull_requests) { ClaudeInbox::PullRequests.new(cache_path: nil, resolved_path: nil, gh: nil) }
  let(:queue) { Queue.new }

  let(:app) { build_app(client:, store:, pull_requests:, queue:, terminal:) }

  after { client.release }

  describe "clicking a row" do
    it "selects it and attaches, same as landing on it and pressing Enter" do
      row = screen(app).index { |l| l.include?("comma3x led flashing") } + 1
      press(app, "\e[<0;5;#{row}M")
      expect(client.attached).to eq(["823b882f"])
      expect(app).to paint("comma3x led flashing").on_selected_row
    end

    it "holds the screen when the attach fails, so its reason can be read" do
      client.fail_attach
      row = screen(app).index { |l| l.include?("comma3x led flashing") } + 1
      press(app, "\e[<0;5;#{row}M")
      expect(terminal.pauses).to eq(1)
    end

    it "goes straight back to the list after an attach that worked" do
      row = screen(app).index { |l| l.include?("comma3x led flashing") } + 1
      press(app, "\e[<0;5;#{row}M")
      expect(terminal.pauses).to eq(0)
    end

    it "refuses on a terminal row instead of attaching, same as Enter" do
      row = screen(app).index { |l| l.include?("claude-inbox-38") } + 1
      press(app, "\e[<0;5;#{row}M")
      expect(client.attached).to be_empty
      expect(app).to paint("terminal").in_status_line
    end

    it "expands a folded section when its toggle line is clicked" do
      store.settle("b03695b1")
      row = screen(app).index { |l| l.include?("… 1 settled") } + 1
      press(app, "\e[<0;5;#{row}M")
      expect(app).to paint("app store release strategy")
    end
  end

  it "moves the selection on a wheel tick, the same way j/k would" do
    expect(app).to paint("comma3x not booting").on_selected_row
    press(app, "\e[<65;1;1M")
    expect(app).to paint("claude-inbox-38").on_selected_row
    press(app, "\e[<64;1;1M")
    expect(app).to paint("comma3x not booting").on_selected_row
  end

  describe "Tab and Shift-Tab" do
    it "walk a section headed by a terminal row like any other, and wrap" do
      store.settle("b03695b1")
      press(app, "\t")
      expect(app).to paint("claude-inbox-38").on_selected_row
      press(app, "\t")
      expect(app).to paint("… 1 settled").on_selected_row
      press(app, "\t")
      expect(app).to paint("comma3x not booting").on_selected_row
      press(app, "\e[Z")
      expect(app).to paint("… 1 settled").on_selected_row
    end
  end

  it "opens, closes and toggles the section under the cursor on zo, zc and za" do
    store.settle("b03695b1")
    press(app, "\t", "\t")
    expect(app).not_to paint("app store release strategy")
    press(app, "z", "o")
    expect(app).to paint("app store release strategy")
    press(app, "\t", "\t")
    expect(app).to paint("app store release strategy").on_selected_row
    press(app, "z", "c")
    expect(app).not_to paint("app store release strategy")
    press(app, "\t", "\t", "z", "a")
    expect(app).to paint("app store release strategy")
  end
end
