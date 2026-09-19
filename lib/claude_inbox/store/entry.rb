# frozen_string_literal: true

module ClaudeInbox
  class Store
    # What the inbox remembers about one session between polls: the snooze,
    # the pin, the hand-settle, the alias, and when the daemon's state last
    # changed. It wraps the hash that state.json holds, and it is the only
    # place the key names appear; everything else reads it through a method.
    #
    # The mutators edit the hash in place, because `Store#edit` yields an
    # Entry over the table's own hash and saves the table afterwards.
    class Entry
      # For a key edited before any poll has seen it, such as `s` on a row
      # that only just appeared.
      def self.blank(now) = new("state_since" => now.to_i)

      # A session the table has no entry for yet. A session we have never seen
      # that is already finished and whose process the supervisor has reaped
      # (no pid) has been quiet since it finished, not since this poll, so its
      # state_since is seeded from started_at and REAP_AFTER's idle clock is
      # accurate from the start instead of running from "now".
      def self.first_seen(session, now)
        since = (session.finished? && !session.alive? && session.started_at) ? session.started_at.to_i : now.to_i
        new("last_state" => session.effective_state, "state_since" => since)
      end

      def self.observe(hash, session, now)
        (hash ? new(hash) : first_seen(session, now)).observe(session, now)
      end

      # Snooze targets, evaluated at `now`. Returns epoch seconds or UNTIL_WOKEN.
      def self.snooze_until(choice, now)
        case choice
        when :m15 then now.to_i + 15 * 60
        when :h1 then now.to_i + 3600
        when :tomorrow_9am
          t = Time.at(now.to_i)
          t9 = Time.new(t.year, t.month, t.day, 9, 0, 0, t.utc_offset)
          t9 += 86_400 if t9 <= t
          t9.to_i
        when :until_woken then UNTIL_WOKEN
        else raise ArgumentError, "unknown snooze #{choice.inspect}"
        end
      end

      def initialize(hash)
        @h = hash
      end

      def to_h = @h

      def alias_name = @h["alias"]

      def pr = @h["pr"]

      def wake_at = @h["wake_at"]

      def parked? = wake_at == UNTIL_WOKEN

      def snoozed_at = @h["snoozed_at"]

      def last_state = @h["last_state"]

      def state_since = @h["state_since"]

      def last_seen = @h["last_seen"]

      def pinned? = @h["pinned"] ? true : false

      def pinned_at = @h["pinned_at"]

      def settled_at = @h["settled_at"]

      def acknowledged_at = @h["acknowledged_at"]

      def revived_at = @h["revived_at"]

      # When `claude rm` last refused this session, so the Reaper backs off.
      def reap_failed_at = @h["reap_failed_at"]

      def reap_error = @h["reap_error"]

      def stale?(now) = last_seen && now.to_i - last_seen > PRUNE_AFTER

      def observe(session, now)
        now_i = now.to_i
        if last_state != session.effective_state
          @h["last_state"] = session.effective_state
          @h["state_since"] = now_i
        end
        @h["last_seen"] = now_i
        row = Row.new(session: session, entry: self)
        @h.delete("wake_at") if row.woken?(now_i)
        @h.delete("snoozed_at") unless wake_at
        @h.delete("settled_at") if settled_at && !row.hand_settled?
        @h.delete("acknowledged_at") if acknowledged_at && !row.acknowledged?
        @h.delete("revived_at") if revived_at && !row.revived?
        self
      end

      def snooze(choice, now)
        @h["wake_at"] = self.class.snooze_until(choice, now)
        @h["snoozed_at"] = now.to_i
      end

      # Also lifts a hand-settle, and forces back any row settled by the PR
      # rule too, so `u` undoes `x` and `s` and a resolved PR alike.
      def wake(now)
        @h.delete("wake_at")
        @h.delete("snoozed_at")
        @h.delete("settled_at")
        @h["revived_at"] = now.to_i
      end

      # Also lifts a prior revive, so `x` after `u` takes hold again even
      # without a state change in between: otherwise revived_at would still
      # outrank the fresh settle in `Row#section`.
      def settle(now)
        @h["settled_at"] = now.to_i
        @h.delete("wake_at")
        @h.delete("snoozed_at")
        @h.delete("revived_at")
      end

      def acknowledge(now)
        @h["acknowledged_at"] = now.to_i
      end

      def toggle_pin(now)
        if @h["pinned"]
          @h.delete("pinned")
          @h.delete("pinned_at")
        else
          @h["pinned"] = true
          @h["pinned_at"] = now.to_i
        end
      end

      def alias=(name)
        name.to_s.empty? ? @h.delete("alias") : @h["alias"] = name
      end

      # Empty clears it and the scanned links show again.
      def pr=(url)
        url.to_s.empty? ? @h.delete("pr") : @h["pr"] = url
      end

      # Records a reap that `claude rm` refused, so the Reaper backs off instead
      # of shelling out every four seconds for ever at a session whose worktree
      # is never going to let go of its unpushed commits.
      def mark_reap_failed(now, message)
        @h["reap_failed_at"] = now.to_i
        @h["reap_error"] = message.to_s.lines.first&.strip
      end
    end
  end
end
