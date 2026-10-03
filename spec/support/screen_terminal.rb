# frozen_string_literal: true

# Stands in for Terminal: a fixed size and the last frame painted, as text.
class ScreenTerminal
  attr_reader :lines, :size

  def initialize
    @size = [80, 27]
    @lines = []
  end

  def paint(lines) = @lines = lines.map { |l| ClaudeInbox::Text.strip_ansi(l) }

  def release = yield

  def enter = nil

  def restore = nil

  def resized = nil

  def invalidate = nil
end
