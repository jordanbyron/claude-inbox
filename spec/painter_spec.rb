# frozen_string_literal: true

require "stringio"

RSpec.describe ClaudeInbox::Painter do
  subject(:painter) { described_class.new(out) }

  let(:out) { StringIO.new }

  it "paints only changed lines" do
    painter.paint(%w[a b c])
    out.truncate(0)
    out.rewind
    painter.paint(%w[a X c])
    expect(out.string).to include "X"
    expect(out.string).not_to include "a"
    expect(out.string).to include "\e[2;1H"
  end

  it "never erases to end of line after a row" do
    painter.paint(%w[a b])
    expect(out.string).not_to include "\e[K"
    expect(out.string).not_to include "\e[0K"
  end
end
