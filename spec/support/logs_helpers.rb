# frozen_string_literal: true

# Readers for the Logs spec; they call the group's `asked` let.
module LogsHelpers
  # Gives the worker thread time to make any request it was going to.
  def settled_asked
    sleep 0.05
    asked
  end
end

RSpec.configure { |config| config.include LogsHelpers, :logs }
