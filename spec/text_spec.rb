# frozen_string_literal: true

RSpec.describe ClaudeInbox::Text do
  it "prints control characters as \\xNN and bad bytes as U+FFFD, so nothing reaches the terminal as an escape" do
    expect(described_class.printable("a\e[2Jb\tc\n")).to eq("a\\x1b[2Jb\\x09c\\x0a")
    expect(described_class.printable("x\xFFy".b)).to eq("x\uFFFDy")
    expect(described_class.printable(nil)).to eq("")
  end

  it "truncates by display width, not characters" do
    expect(described_class.truncate("ab🎉cd", 3)).to eq("ab…")
    expect(described_class.truncate("ab🎉cdef", 5)).to eq("ab🎉…")
    expect(described_class.truncate("abc", 3)).to eq("abc")
  end

  it "drops leading columns by display width" do
    expect(described_class.drop("ab🎉cd", 2)).to eq("🎉cd")
    expect(described_class.drop("ab🎉cd", 3)).to eq("cd")
  end

  it "pads ignoring ANSI" do
    s = "\e[31mred\e[0m"
    expect(described_class.width(s + "  ")).to eq(5)
    expect(described_class.pad(s, 5)).to eq(s + "  ")
  end

  it "wraps on display width" do
    expect(described_class.wrap("the quick brown fox", 9)).to eq(["the quick", "brown fox"])
    expect(described_class.wrap("abcdefghij", 4)).to eq(%w[abcd efgh ij])
    expect(described_class.wrap("short", 10)).to eq(["short"])
  end

  it "humanises ages" do
    expect(described_class.age(45)).to eq("45s")
    expect(described_class.age(12 * 60 + 5)).to eq("12m")
    expect(described_class.age(3 * 3600)).to eq("3h")
    expect(described_class.age(2 * 86_400 + 5)).to eq("2d")
  end
end
