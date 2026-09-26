# frozen_string_literal: true

RSpec.describe ClaudeInbox::Config, :config do
  it "is the typed arguments alone without a config file" do
    expect(argv_with(nil, ["--no-color"])).to eq(["--no-color"])
  end

  it "puts the file's arguments before the typed ones" do
    expect(argv_with("--listen-lan\n", ["--listen=7500"])).to eq(["--listen-lan", "--listen=7500"])
  end

  it "skips comments and blank lines and splits a line like a shell" do
    config = <<~CONFIG
      # arm the phone form
      --listen-lan --listen-allow-modes=default,plan  # no auto

      "--no-color"
    CONFIG
    expect(argv_with(config)).to eq(["--listen-lan", "--listen-allow-modes=default,plan", "--no-color"])
  end

  it "names the file when a line won't parse" do
    expect { argv_with("--listen-lan \"\n") }.to raise_error(ArgumentError, /config: /)
  end
end
