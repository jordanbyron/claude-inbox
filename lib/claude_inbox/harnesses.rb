# frozen_string_literal: true

module ClaudeInbox
  # Every harness's adapter behind one client: the list is all of theirs,
  # and an action on a session goes to the adapter that made it. Adopting
  # is Claude's alone, and so is a start that names no harness. T3 runs
  # other harnesses' agents, so a start goes to it for any harness it has
  # ready, and Codex falls back to its own daemon when T3 has not.
  class Harnesses
    # What an adapter raises when its harness refuses, or is not there to ask.
    class Error < StandardError; end

    def initialize(**adapters)
      @adapters = adapters
    end

    def list = @adapters.values.flat_map(&:list)

    def pulse = @adapters.values.map(&:pulse)

    # False when the attach failed; else true, or the key of the row the
    # attached session asked to go to next.
    def attach(session, &) = adapter(session).attach(session, &)

    def stop(session) = adapter(session).stop(session)

    def rm(session) = adapter(session).rm(session)

    def spawn(harness: :claude, **)
      return t3.spawn(harness: harness, **) if route(harness) == :t3
      raise Error, "#{harness} runs on T3 Code, which is not running or has no #{harness} ready" unless @adapters.key?(harness)
      @adapters.fetch(harness).spawn(**)
    end

    # The adapter a start of `harness` goes to now.
    def route(harness) = t3_offers[harness] ? :t3 : harness

    # Each harness that could start a session now, with what its form
    # offers; nil for one that only T3 could start, and can't now.
    def choices = @adapters.except(:t3).transform_values(&:choices).reject { |_, choices| choices.empty? }.merge(t3_offers)

    def adopt(**) = claude.adopt(**)

    def remote_url(id) = claude.remote_url(id)

    private

    def claude = @adapters.fetch(:claude)

    def t3 = @adapters.fetch(:t3)

    def t3_offers = @adapters.key?(:t3) ? t3.choices : {}

    def adapter(session) = @adapters.fetch(session.harness)
  end
end
