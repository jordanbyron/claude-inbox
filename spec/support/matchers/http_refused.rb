# frozen_string_literal: true

# Passes when the block raises an Http::Error carrying `status`.
RSpec::Matchers.define :be_http_refused_with do |status|
  supports_block_expectations

  match do |block|
    block.call
    false
  rescue ClaudeInbox::Remote::Http::Error => e
    @raised = e
    e.status == status
  end

  failure_message do
    got = @raised ? "#{@raised.status} (#{@raised.message})" : "nothing raised"
    "expected an Http::Error with status #{status}, got #{got}"
  end

  failure_message_when_negated do
    "expected no Http::Error with status #{status}, got one (#{@raised.message})"
  end
end
