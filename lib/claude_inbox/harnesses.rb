# frozen_string_literal: true

require "delegate"

module ClaudeInbox
  # The Claude adapter with the other harnesses' sessions added to its
  # list. Every action still goes to Claude, since no other harness's
  # sessions offer one yet.
  class Harnesses < SimpleDelegator
    def initialize(claude, others)
      super(claude)
      @others = others
    end

    def list = __getobj__.list + @others.flat_map(&:list)
  end
end
