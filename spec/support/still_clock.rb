# frozen_string_literal: true

# A clock that stands still until an example moves it.
class StillClock
  def initialize(now)
    @now = now
  end

  def call = @now

  def advance(seconds)
    @now += seconds
  end
end
