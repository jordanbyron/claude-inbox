# frozen_string_literal: true

# Stands in for Terminal: a fixed size and the last frame painted, as text.
class ScreenTerminal
  attr_reader :lines

  def initialize(width: 80, height: 27)
    @size = [width, height]
    @lines = []
  end

  attr_reader :size

  def paint(lines) = @lines = lines.map { |l| ClaudeInbox::Text.strip_ansi(l) }

  def release = yield

  def enter = nil

  def restore = nil

  def resized = nil

  def invalidate = nil
end
