# frozen_string_literal: true

# Reads what the Terminal under test wrote since the last read; needs the
# group's `out` let.
module TerminalHelpers
  # StringIO#string hands back the live buffer, so copy before clearing it.
  def taken = out.string.dup.tap {
    out.truncate(0)
    out.rewind
  }
end

RSpec.configure { |config| config.include TerminalHelpers, :terminal }
