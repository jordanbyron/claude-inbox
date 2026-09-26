# frozen_string_literal: true

require_relative "test_helper"
require_relative "../release/next_version"

describe Release::NextVersion do
  def next_version(current, *messages) = Release::NextVersion.new(current, messages)

  it "releases nothing when no commit is a feat, fix or breaking change" do
    _(next_version("1.2.3", "docs: fix a typo (#1)", "refactor: rename (#2)", "chore: bump deps").version).must_be_nil
  end

  it "bumps patch for a fix" do
    _(next_version("1.2.3", "docs: fix a typo (#1)", "fix: stop crashing (#2)").version).must_equal "1.2.4"
  end

  it "bumps minor for a feat, over any fix" do
    _(next_version("1.2.3", "fix: stop crashing (#2)", "feat(ui): add a key (#3)").version).must_equal "1.3.0"
  end

  it "bumps major for a bang, over any feat" do
    _(next_version("1.2.3", "feat: add a key (#3)", "refactor(store)!: drop the old file (#4)").version).must_equal "2.0.0"
  end

  it "bumps major for a BREAKING CHANGE footer" do
    message = "fix: rename the config key (#5)\n\nBREAKING CHANGE: the old key is ignored.\n"
    _(next_version("1.2.3", message).version).must_equal "2.0.0"
  end

  it "bumps minor for a breaking change while the version is 0.x" do
    _(next_version("0.4.2", "feat!: change the JSON (#6)").version).must_equal "0.5.0"
  end

  it "does not read BREAKING CHANGE out of a subject" do
    _(next_version("1.2.3", "docs: explain BREAKING CHANGE: footers (#7)").version).must_be_nil
  end

  it "names the bump" do
    _(next_version("1.2.3", "fix: x").bump).must_equal :patch
    _(next_version("1.2.3", "docs: x").bump).must_be_nil
  end
end
