# frozen_string_literal: true

# Keys and clicks sent to the App, and reads of the frame it paints next.
# Calls the group's `app` and `terminal`.
module AppScreenHelpers
  def press(*keys) = keys.each { |k| app.step(k) }

  def screen
    app.step
    terminal.lines
  end

  def status_line = screen.first

  def footer = screen.last

  def selected_line = screen.find { |l| l.include?("▶") }

  # The selected row's key: the row itself carries a live age and spinner.
  def cursor
    app.step
    app.instance_variable_get(:@selected)&.key
  end

  def row_of(label) = screen.index { |l| l.include?(label) } + 1

  def click(col, row) = press("\e[<0;#{col};#{row}M")
end

RSpec.configure { |config| config.include AppScreenHelpers, :app_screen }
