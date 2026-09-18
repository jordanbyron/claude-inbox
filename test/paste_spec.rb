# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/claude_inbox/paste"

describe ClaudeInbox::Paste do
  let(:paste) { ClaudeInbox::Paste.new }

  it "passes plain keys through untouched" do
    _(paste.feed("j")).must_equal [[:key, "j"]]
    _(paste.feed("\e[<0;5;3M")).must_equal [[:key, "\e[<0;5;3M"]]
  end

  it "hands over a paste whole, keys either side kept apart" do
    _(paste.feed("j\e[200~hello world\e[201~k")).must_equal [[:key, "j"], [:paste, "hello world"], [:key, "k"]]
  end

  it "reassembles a paste split across reads" do
    _(paste.feed("\e[200~hel")).must_equal []
    _(paste.feed("lo")).must_equal []
    _(paste.feed(" world\e[201~")).must_equal [[:paste, "hello world"]]
  end

  it "reports an empty paste, which is how an image arrives" do
    _(paste.feed("\e[200~\e[201~")).must_equal [[:paste, ""]]
  end
end
