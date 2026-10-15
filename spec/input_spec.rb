# frozen_string_literal: true

require "stringio"

RSpec.describe ClaudeInbox::Input do
  subject(:input) { described_class.new(StringIO.new, StringIO.new) }

  it "names a key the reader knows and passes the rest through as themselves" do
    expect(input.events("j")).to eq([[:key, "j", "j"]])
    expect(input.events("\e[A")).to eq([[:key, :up, "\e[A"]])
  end

  it "splits a glued escape from the keys typed after it" do
    expect(input.events("\egg")).to eq([[:key, :escape, "\e"], [:key, "g", "g"], [:key, "g", "g"]])
  end

  it "hands a paste over once it closes, and says it is open until then" do
    expect(input.events("\e[200~hel")).to eq([])
    expect(input).to be_pasting
    expect(input.events("lo\e[201~k")).to eq([[:paste, "hello"], [:key, "k", "k"]])
    expect(input).not_to be_pasting
  end

  it "turns a mouse report into a mouse event" do
    expect(input.events("\e[<0;5;3M")).to eq([[:mouse, ClaudeInbox::Mouse::Event.new(:click, 3, 5)]])
  end

  it "names the characters of a paste typed out" do
    expect(input.typed("a\r")).to eq([["a", "a"], [:return, "\r"]])
  end
end
