# frozen_string_literal: true

# Keystrokes for the TextBuffer specs.
module TextBufferHelpers
  def type(buffer, str) = str.each_char { |c| buffer.press(c, c) }
end

RSpec.configure { |config| config.include TextBufferHelpers, :text_buffer }
