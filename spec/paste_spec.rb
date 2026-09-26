# frozen_string_literal: true

require_relative "../lib/claude_inbox/paste"

RSpec.describe ClaudeInbox::Paste do
  let(:paste) { ClaudeInbox::Paste.new }

  it "passes plain keys through untouched" do
    expect(paste.feed("j")).to eq([[:key, "j"]])
    expect(paste.feed("\e[<0;5;3M")).to eq([[:key, "\e[<0;5;3M"]])
  end

  it "hands over a paste whole, keys either side kept apart" do
    expect(paste.feed("j\e[200~hello world\e[201~k")).to eq([[:key, "j"], [:paste, "hello world"], [:key, "k"]])
  end

  it "reassembles a paste split across reads" do
    expect(paste.feed("\e[200~hel")).to eq([])
    expect(paste.feed("lo")).to eq([])
    expect(paste.feed(" world\e[201~")).to eq([[:paste, "hello world"]])
  end

  it "reports an empty paste, which is how an image arrives" do
    expect(paste.feed("\e[200~\e[201~")).to eq([[:paste, ""]])
  end
end
