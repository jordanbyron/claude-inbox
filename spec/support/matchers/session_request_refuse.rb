# frozen_string_literal: true

# Passes when the block raises a SessionRequest::Invalid whose field and
# message match; the field may be `anything`, and a message left out is not checked.
RSpec::Matchers.define :refuse_as do |field, message = nil|
  supports_block_expectations

  match do |block|
    block.call
    false
  rescue ClaudeInbox::SessionRequest::Invalid => e
    @raised = e
    values_match?(field, e.field) && (message.nil? || values_match?(message, e.message))
  end

  failure_message do
    got = @raised ? [@raised.field, @raised.message].inspect : "nothing raised"
    "expected SessionRequest::Invalid #{[field, message].inspect}, got #{got}"
  end
end
