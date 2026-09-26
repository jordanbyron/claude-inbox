# frozen_string_literal: true

# Passes when the App's next frame shows `text` (a string it includes, or a
# pattern it matches): the whole screen, or with a chain, one line of it.
# App#step paints before it handles a key, so the matcher steps once more
# to see what the last key did.
RSpec::Matchers.define :paint do |text|
  chain(:in_status_line) { @where = :status_line }
  chain(:in_footer) { @where = :footer }
  chain(:on_selected_row) { @where = :selected_row }

  match do |app|
    app.step
    lines = app.instance_variable_get(:@terminal).lines
    @painted = case @where
    when :status_line then lines.first
    when :footer then lines.last
    when :selected_row then lines.find { |l| l.include?("▶") }.to_s
    else lines.join("\n")
    end
    text.is_a?(Regexp) ? text.match?(@painted) : @painted.include?(text)
  end

  failure_message { "expected the #{@where || :screen} to show #{text.inspect}, got:\n#{@painted}" }

  failure_message_when_negated { "expected the #{@where || :screen} not to show #{text.inspect}, got:\n#{@painted}" }
end
