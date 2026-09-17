# frozen_string_literal: true

require_relative "test_helper"

Palette = ClaudeInbox::Palette

describe Palette do
  let(:palette) { Palette.new(enabled: true) }

  it "paints the six session colours ansi can name with the terminal's own colour" do
    _(palette.paint("x", "red")).must_equal "\e[31mx\e[39m"
    _(palette.paint("x", "green")).must_equal "\e[32mx\e[39m"
    _(palette.paint("x", "yellow")).must_equal "\e[33mx\e[39m"
    _(palette.paint("x", "blue")).must_equal "\e[34mx\e[39m"
    _(palette.paint("x", "purple")).must_equal "\e[35mx\e[39m"
    _(palette.paint("x", "cyan")).must_equal "\e[36mx\e[39m"
  end

  it "falls back to a 256-colour index for the two ansi has no name for" do
    _(palette.paint("x", "orange")).must_equal "\e[38;5;208mx\e[39m"
    _(palette.paint("x", "pink")).must_equal "\e[38;5;205mx\e[39m"
  end

  it "closes with a default-foreground reset so it never clears bold or italic" do
    _(palette.paint("\e[1mx\e[0m", "red")).must_equal "\e[31m\e[1mx\e[0m\e[39m"
  end

  it "leaves text alone for a colour it does not know, or none at all" do
    _(palette.paint("x", nil)).must_equal "x"
    _(palette.paint("x", "chartreuse")).must_equal "x"
    _(palette.paint("x", "")).must_equal "x"
  end

  it "leaves text alone when colour is off" do
    _(Palette.new(enabled: false).paint("x", "orange")).must_equal "x"
  end

  it "knows which colours it can paint" do
    _(Palette.known?("orange")).must_equal true
    _(Palette.known?("chartreuse")).must_equal false
    _(Palette.known?(nil)).must_equal false
  end
end
