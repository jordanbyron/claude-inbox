# frozen_string_literal: true

# Feeds a string to a fresh VtScreen of the given size.
module VtScreenHelpers
  def screen(str, **kw) = ClaudeInbox::VtScreen.new(**kw).feed(str)
end

RSpec.configure { |config| config.include VtScreenHelpers, :vt_screen }
