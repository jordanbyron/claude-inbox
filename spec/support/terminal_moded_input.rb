# frozen_string_literal: true

# A tty with a mode of its own, as io/console exposes one.
class ModedInput < StringIO
  attr_reader :modes

  def initialize
    super
    @modes = [:shell]
  end

  def tty? = true

  def raw! = @modes << :raw

  def console_mode = @modes.last

  def console_mode=(mode)
    @modes << mode
  end
end
