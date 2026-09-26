# frozen_string_literal: true

require_relative "test_helper"
require "claude_inbox/config"
require "tmpdir"

describe ClaudeInbox::Config do
  def argv_with(contents, typed = [])
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config")
      File.write(path, contents) if contents
      ClaudeInbox::Config.argv(typed, path: path)
    end
  end

  it "is the typed arguments alone without a config file" do
    _(argv_with(nil, ["--no-color"])).must_equal ["--no-color"]
  end

  it "puts the file's arguments before the typed ones" do
    _(argv_with("--listen-lan\n", ["--listen=7500"])).must_equal ["--listen-lan", "--listen=7500"]
  end

  it "skips comments and blank lines and splits a line like a shell" do
    config = <<~CONFIG
      # arm the phone form
      --listen-lan --listen-allow-modes=default,plan  # no auto

      "--no-color"
    CONFIG
    _(argv_with(config)).must_equal ["--listen-lan", "--listen-allow-modes=default,plan", "--no-color"]
  end

  it "names the file when a line won't parse" do
    error = _ { argv_with("--listen-lan \"\n") }.must_raise ArgumentError
    _(error.message).must_match(/config: /)
  end
end
