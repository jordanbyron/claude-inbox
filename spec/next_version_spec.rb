# frozen_string_literal: true

require_relative "../release/next_version"

RSpec.describe Release::NextVersion do
  it "releases nothing when no commit is a feat, fix or breaking change" do
    expect(described_class.new("1.2.3", ["docs: fix a typo (#1)", "refactor: rename (#2)", "chore: bump deps"]).version).to be_nil
  end

  it "bumps patch for a fix" do
    expect(described_class.new("1.2.3", ["docs: fix a typo (#1)", "fix: stop crashing (#2)"]).version).to eq("1.2.4")
  end

  it "bumps minor for a feat, over any fix" do
    expect(described_class.new("1.2.3", ["fix: stop crashing (#2)", "feat(ui): add a key (#3)"]).version).to eq("1.3.0")
  end

  it "bumps major for a bang, over any feat" do
    expect(described_class.new("1.2.3", ["feat: add a key (#3)", "refactor(store)!: drop the old file (#4)"]).version).to eq("2.0.0")
  end

  it "bumps major for a BREAKING CHANGE footer" do
    message = "fix: rename the config key (#5)\n\nBREAKING CHANGE: the old key is ignored.\n"
    expect(described_class.new("1.2.3", [message]).version).to eq("2.0.0")
  end

  it "bumps minor for a breaking change while the version is 0.x" do
    expect(described_class.new("0.4.2", ["feat!: change the JSON (#6)"]).version).to eq("0.5.0")
  end

  it "does not read BREAKING CHANGE out of a subject" do
    expect(described_class.new("1.2.3", ["docs: explain BREAKING CHANGE: footers (#7)"]).version).to be_nil
  end

  it "names the bump" do
    expect(described_class.new("1.2.3", ["fix: x"]).bump).to eq(:patch)
    expect(described_class.new("1.2.3", ["docs: x"]).bump).to be_nil
  end
end
