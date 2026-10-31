# frozen_string_literal: true

module ClaudeInbox
  # Every harness's adapter behind one client: the list is all of theirs,
  # and an action on a session goes to the adapter that made it. Adopting
  # is Claude's alone, and so is a start that names no harness.
  class Harnesses
    # What an adapter raises when its harness refuses, or is not there to ask.
    class Error < StandardError; end

    def initialize(**adapters)
      @adapters = adapters
    end

    def list = @adapters.values.flat_map(&:list)

    def pulse = @adapters.values.map(&:pulse)

    def attach(session, &) = adapter(session).attach(session, &)

    def stop(session) = adapter(session).stop(session)

    def rm(session) = adapter(session).rm(session)

    def spawn(harness: :claude, **) = @adapters.fetch(harness).spawn(**)

    # Each harness that could start a session now, with what its form offers.
    def choices = @adapters.transform_values(&:choices).reject { |_, choices| choices.empty? }

    def adopt(**) = claude.adopt(**)

    def remote_url(id) = claude.remote_url(id)

    private

    def claude = @adapters.fetch(:claude)

    def adapter(session) = @adapters.fetch(session.harness)
  end
end
