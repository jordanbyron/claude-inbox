# frozen_string_literal: true

# The few verbs every spec may use. Each takes what it drives as an argument,
# so none depends on a spec defining a particular let.
module Drivers
  FIXTURES = File.expand_path("../fixtures", __dir__)

  def fixture_path(name) = File.join(FIXTURES, name)

  def session(**attrs)
    ClaudeInbox::Session.new(
      id: "abc12345", cwd: "/tmp/proj", kind: "background",
      started_at: Time.at(1_789_400_000), state: "working", name: "thing", **attrs
    )
  end

  def wait_for(timeout: 2)
    deadline = Time.now + timeout
    sleep 0.01 while !yield && Time.now < deadline
    yield
  end

  # What arrived since the last drain: a Queue's items, or a StringIO's text.
  def drain(source)
    return Array.new(source.size) { source.pop(true) } if source.is_a?(Queue)

    source.string.dup.tap {
      source.truncate(0)
      source.rewind
    }
  end

  def press(app, *keys) = keys.each { |k| app.step(k) }

  # One more step first, so whatever a background worker queued since the
  # last key is on the screen.
  def screen(app)
    app.step
    app.instance_variable_get(:@terminal).lines
  end

  def type(input, text) = text.each_char { |c| input.press(c, c) }
end

PNG = "\x89PNG\r\n\x1A\n#{"\0" * 16}".b

RSpec.configure { |config| config.include Drivers }
