# frozen_string_literal: true

# Frames rendered for the renderer specs. Relies on the group's let values
# now and renderer, and on sections for the default frame.
module RendererHelpers
  def view(width: 80, height: 24, **o) = ClaudeInbox::Renderer::View.new(width: width, height: height, now: now, **o)

  def frame(sec = sections, **o) = renderer.frame(sec, view(**o))

  def colored(name, **attrs)
    session(id: "z", name: "tinted", job_state: ClaudeInbox::JobState.new("color" => name), **attrs)
  end

  def line_for(session, entries = {}, **opts)
    sec = ClaudeInbox::Store.sectionize([session], ClaudeInbox::Store.merge_entries(entries, [session], now), now)
    frame(sec, width: 80, height: 14, **opts).lines.find { |l| l.include?(session.name) }
  end
end

RSpec.configure { |config| config.include RendererHelpers, :renderer }
