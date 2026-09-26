# frozen_string_literal: true

Palette = ClaudeInbox::Palette

RSpec.describe Palette do
  let(:palette) { Palette.new(enabled: true) }

  it "paints the six session colors ansi can name with the terminal's own color" do
    expect(palette.paint("x", "red")).to eq("\e[31mx\e[39m")
    expect(palette.paint("x", "green")).to eq("\e[32mx\e[39m")
    expect(palette.paint("x", "yellow")).to eq("\e[33mx\e[39m")
    expect(palette.paint("x", "blue")).to eq("\e[34mx\e[39m")
    expect(palette.paint("x", "purple")).to eq("\e[35mx\e[39m")
    expect(palette.paint("x", "cyan")).to eq("\e[36mx\e[39m")
  end

  it "falls back to a 256-color index for the two ansi has no name for" do
    expect(palette.paint("x", "orange")).to eq("\e[38;5;208mx\e[39m")
    expect(palette.paint("x", "pink")).to eq("\e[38;5;205mx\e[39m")
  end

  it "closes with a default-foreground reset so it never clears bold or italic" do
    expect(palette.paint("\e[1mx\e[0m", "red")).to eq("\e[31m\e[1mx\e[0m\e[39m")
  end

  it "leaves text alone for a color it does not know, or none at all" do
    expect(palette.paint("x", nil)).to eq("x")
    expect(palette.paint("x", "chartreuse")).to eq("x")
    expect(palette.paint("x", "")).to eq("x")
  end

  it "leaves text alone when color is off" do
    expect(Palette.new(enabled: false).paint("x", "orange")).to eq("x")
  end
end
