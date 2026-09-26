# frozen_string_literal: true

# Passes when a dialog's frame, drawn 120 columns wide, shows `text`.
RSpec::Matchers.define :show do |text|
  match { |dialog| (@frame = dialog.frame(120).join("\n")).include?(text) }

  failure_message { "expected the frame to show #{text.inspect}, got:\n#{@frame}" }

  failure_message_when_negated { "expected the frame not to show #{text.inspect}, got:\n#{@frame}" }
end
