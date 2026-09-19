# frozen_string_literal: true

module ClaudeInbox
  class Store
    # A session paired with its Entry: the value the triage rules are written
    # on. The entry is nil for a session no poll has recorded yet. A Row is
    # pure; every rule that needs the clock takes `now`, so the same Row
    # answers the same way in a spec and in a poll.
    Row = Struct.new(:session, :entry) do
      def id = session.id

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

      # What `/` searches: the label as shown, or the working directory.
      def matches?(query)
        q = query.downcase
        label.downcase.include?(q) || session.cwd.to_s.downcase.include?(q)
      end

      # Wake rule: a snoozed session comes back when the timer ran out or when
      # it *becomes* blocked/failed after being snoozed. A session that was
      # already blocked when you snoozed it stays snoozed — that is the point.
      def woken?(now)
        return false if wake_at.nil?
        return true if session.needs_you? && entry.state_since.to_i > entry.snoozed_at.to_i
        return false if parked?
        wake_at.to_i <= now.to_i
      end

      def snoozed?(now) = wake_at && !woken?(now)

      # Hand-settle rule: `x` parks a row in Settled whatever the clock says. It
      # comes back when the session changes state afterwards and is not merely
      # finishing: working again, blocked, or failed. Finishing keeps it parked.
      def hand_settled?
        return false unless entry&.settled_at
        session.finished? || entry.state_since.to_i <= entry.settled_at.to_i
      end

      # Acknowledge rule: attaching to a session marks its current state seen, so
      # it drops out of Needs You without being archived to Settled. It comes
      # back the moment the state changes again — same "state_since" test as
      # hand-settle, just routed to Active instead of Settled.
      def acknowledged?
        entry&.acknowledged_at && entry.state_since.to_i <= entry.acknowledged_at.to_i
      end

      # Revive rule: `u` forces a settled row back to wherever its raw state
      # puts it, overriding hand-settle and the resolved-PR rule alike. Same
      # "state_since" test as the other two, so it holds until the state
      # actually changes again rather than just for the next poll.
      def revived?
        entry&.revived_at && entry.state_since.to_i <= entry.revived_at.to_i
      end

      # Settle rule: hand-settled (`x`), or every pull request resolved. That
      # holds however the session ended its turn, not just when it ran to
      # `done` — opening a PR and asking "anything need changing?" leaves it
      # `blocked`, and merging the PR answers the question, so the row has
      # nothing left to say. A PR whose state nobody knows yet (no gh, offline)
      # is ignored. A session with no pull request at all never settles on its
      # own; only `x` parks it.
      #
      # `working` and `failed` never settle this way: `working` is still going,
      # and `failed` is a failure you should see even if the PR it had already
      # opened went on to land.
      def settled?
        return true if hand_settled?
        return false if UNSETTLEABLE.include?(session.effective_state)
        known = session.prs.select(&:known?)
        known.any? && known.all?(&:resolved?)
      end

      # Reap rule: a background session quiet for REAP_AFTER goes to `claude
      # rm`, which takes its transcript and its worktree with it.
      #
      # Not keyed on the Settled section, on purpose. Settling answers "should I
      # still be looking at this?", and the PR rule holds a row in Active for as
      # long as a pull request stays open — so an abandoned draft parks a session
      # there for ever, and the deadest rows in the list are precisely the ones
      # Settled never reaches. Idle time is the only clock here.
      #
      # Three things veto a reap, each an explicit "keep this": a pin, a snooze,
      # and a live process. An interactive session has no id, so there is nothing
      # to reap it with. A session with no entry is spared too: merge_entries
      # writes one on the same poll, seeding `state_since` from `started_at`, so
      # it comes back round in seconds with an idle time worth trusting instead
      # of being reaped on a guess.
      def reapable?(now)
        return false unless session.actionable?
        return false if session.alive?
        return false if UNREAPABLE.include?(session.effective_state)
        return false if entry.nil? || pinned? || snoozed?(now)
        !state_since.nil? && now.to_i - state_since.to_i > REAP_AFTER
      end

      # Which section the row belongs in. Sitting in the terminal outranks
      # everything: never settle or hide a session you are in. Then a pin
      # parks the row at the top regardless of its state.
      def section(now)
        if session.terminal? then session.needs_you? ? :needs_you : :active
        elsif pinned? then :pinned
        elsif snoozed?(now) then :snoozed
        elsif !revived? && hand_settled? then :settled
        elsif !revived? && settled? then :settled # a resolved PR outranks Needs You
        elsif session.needs_you? then acknowledged? ? :active : :needs_you
        elsif session.finished? then :active
        else :active
        end
      end
    end
  end
end
