# frozen_string_literal: true

module ClaudeInbox
  class Store
    # A session paired with its Entry (nil until a poll has recorded one), with
    # the triage rules as its methods; each takes `now`, so a Row is pure.
    Row = Struct.new(:session, :entry) do
      def key = session.key

      def selectable? = !key.nil?

      def alias_name = entry&.alias_name

      def label = alias_name || session.display_name

      def wake_at = entry&.wake_at

      def parked? = entry&.parked?

      def state_since = entry&.state_since

      def pinned_at = entry&.pinned_at

      def pinned? = entry&.pinned?

      def reap_failed_at = entry&.reap_failed_at

      # Names get shortened and forgotten, so the filter also reads what the
      # session was asked to do and what it says it is doing now.
      def matches?(query)
        q = query.downcase
        [label, session.cwd, session.intent, session.summary].any? { |field| field.to_s.downcase.include?(q) }
      end

      # A session already blocked when you snoozed it stays snoozed; one that
      # *becomes* blocked or fails afterwards wakes early.
      def woken?(now)
        return false if wake_at.nil?
        return true if session.needs_you? && entry.state_since.to_i > entry.snoozed_at.to_i
        return false if parked?
        wake_at.to_i <= now.to_i
      end

      def snoozed?(now) = wake_at && !woken?(now)

      # `x` holds through the session finishing; any other state change afterwards lifts it.
      def hand_settled?
        return false unless entry&.settled_at
        session.finished? || entry.state_since.to_i <= entry.settled_at.to_i
      end

      # Attaching marks the current state seen: out of Needs You, but into
      # Active rather than Settled, until the state changes again.
      def acknowledged?
        entry&.acknowledged_at && entry.state_since.to_i <= entry.acknowledged_at.to_i
      end

      # Finished or needing you, so it carries a read or unread mark. Only a
      # session you can attach to counts, since nothing else ever clears it.
      def markable? = session.actionable? && (session.finished? || session.needs_you?)

      # Finished or needing you since you last attached.
      def unread?
        return false unless markable?
        entry&.last_visited_at.nil? || entry.state_since.to_i > entry.last_visited_at.to_i
      end

      # A finished or blocked session you have attached to since: you have seen what it wants.
      def read? = markable? && !unread?

      # `u` overrides hand-settle and the PR rule alike, and holds until the
      # state actually changes rather than just for the next poll.
      def revived?
        entry&.revived_at && entry.state_since.to_i <= entry.revived_at.to_i
      end

      # Failing checks or requested changes on the PR want you back the way
      # a blocked session does, once the agent has stopped working on it.
      # Only an open PR gh has described has a health, so the unknown and
      # the long-resolved PRs `settled?` guards against never count here.
      # Entry#observe treats a change of health as a state change, so
      # attaching answers it until the health changes again.
      def pr_needs_you?
        session.effective_state != "working" && session.pr&.needs_you? == true
      end

      # Resolved PRs settle a `blocked` row too: asking "anything need
      # changing?" leaves it blocked, and merging answers it. `failed` stays
      # in view even if its PR landed; a PR nobody knows the state of yet
      # (no gh, offline) is ignored. So is one resolved before the session
      # started: reviewing an old PR, or the CLI resolving a bare PR number
      # against the wrong repo, would otherwise hide a session waiting on you.
      # Until gh says when a PR was resolved, it holds the row in view.
      def settled?
        return true if hand_settled?
        return false if UNSETTLEABLE.include?(session.effective_state)
        started = session.created_at.to_i
        ours = session.prs.select(&:known?).reject { |pr| pr.resolved_before?(started) }
        ours.any? && ours.all? { |pr| pr.resolved_since?(started) }
      end

      # Idle time is the only clock, not the Settled section: the PR rule holds
      # an abandoned draft in Active for ever, so the deadest rows are the ones
      # Settled never reaches. A session with no entry waits a poll, so its
      # idle time is seeded from `started_at` rather than guessed.
      def reapable?(now)
        return false unless session.actionable?
        return false if session.alive?
        return false if UNREAPABLE.include?(session.effective_state)
        return false if entry.nil? || pinned? || snoozed?(now)
        !state_since.nil? && now.to_i - state_since.to_i > REAP_AFTER
      end

      # The terminal outranks everything: never settle or hide a session you are in.
      def section(now)
        if session.terminal? then session.needs_you? ? :needs_you : :active
        elsif pinned? then :pinned
        elsif snoozed?(now) then :snoozed
        elsif !revived? && settled? then :settled # a resolved PR outranks Needs You
        elsif session.needs_you? || pr_needs_you? then acknowledged? ? :active : :needs_you
        else :active
        end
      end
    end
  end
end
