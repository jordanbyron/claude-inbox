# frozen_string_literal: true

# Stands in for Terminal: a fixed size, the last frame painted, as text, and
# how many times a failed child held the screen.
class ScreenTerminal
  attr_reader :lines, :size, :pauses

  def initialize
    @size = [80, 27]
    @lines = []
    @pauses = 0
  end

  def paint(lines) = @lines = lines.map { |l| ClaudeInbox::Text.strip_ansi(l) }

  def release = yield

  def pause = @pauses += 1

  def enter = nil

  def restore = nil

  def resized = nil

  def invalidate = nil
end
