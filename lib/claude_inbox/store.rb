# frozen_string_literal: true

require "json"
require "tmpdir"
require_relative "json_file"

module ClaudeInbox
  # Snapshot of the last poll plus the per-session snooze table.
  #
  # All triage rules live in the pure class methods `merge_entries` and
  # `sectionize`; the instance is a thin mutex-guarded holder around them
  # with a JSON file behind it.
  class Store
    SETTLE_AFTER = 10 * 60      # seconds a done/stopped session stays quiet before settling
    PRUNE_AFTER = 7 * 24 * 3600 # forget entries not seen in a poll for this long
    REAP_AFTER = 14 * 24 * 3600 # seconds idle before a session is deleted outright
    UNTIL_WOKEN = "until_woken"
    # States that hold a row open no matter what its pull requests did.
    UNSETTLEABLE = %w[working failed].freeze
    # States never reaped, however long they have been quiet. Shorter than
    # UNSETTLEABLE on purpose: `failed` earns a permanent row because you
    # should see it, but after REAP_AFTER of not seeing it, you never will.
    UNREAPABLE = %w[working].freeze
    SECTIONS = %i[pinned needs_you active snoozed settled].freeze
    # Sections long enough to be worth hiding behind a fold toggle.
    FOLDABLE_SECTIONS = %i[snoozed settled].freeze

    Sections = Struct.new(:pinned, :needs_you, :active, :snoozed, :settled) do
      def each_section = SECTIONS.each { |k| yield k, self[k] }

      def all = SECTIONS.flat_map { |k| self[k] }
    end

    # A session paired with its store entry and computed presentation bits.
    Row = Struct.new(:session, :entry, :section) do
      def id = session.id

      def alias_name = entry && entry["alias"]

      def label = alias_name || session.display_name

      def wake_at = entry && entry["wake_at"]

      def parked? = wake_at == UNTIL_WOKEN

      def state_since = entry && entry["state_since"]

      def pinned? = entry && entry["pinned"] == true

      def pinned_at = entry && entry["pinned_at"]

      def key = session.key

      def selectable? = !key.nil?
    end

    # ----- pure rules -------------------------------------------------------

    # Fold a fresh poll into the entry table. Returns a new table.
    #   * bumps `state_since` only when `state` actually changed
    #   * records `last_seen`
    #   * clears an elapsed or overridden snooze (wake rule) or hand-settle
    #   * prunes entries not seen for PRUNE_AFTER
    def self.merge_entries(entries, sessions, now)
      now_i = now.to_i
      out = {}
      entries.each do |id, e|
        next if e["last_seen"] && now_i - e["last_seen"] > PRUNE_AFTER
        out[id] = e.dup
      end
      sessions.each do |s|
        next unless s.key
        e = out[s.key] ||= {"last_state" => s.effective_state, "state_since" => first_seen_since(s, now_i)}
        if e["last_state"] != s.effective_state
          e["last_state"] = s.effective_state
          e["state_since"] = now_i
        end
        e["last_seen"] = now_i
        e.delete("wake_at") if woken?(s, e, now_i)
        e.delete("snoozed_at") unless e["wake_at"]
        e.delete("settled_at") if e["settled_at"] && !hand_settled?(s, e)
        e.delete("acknowledged_at") if e["acknowledged_at"] && !acknowledged?(s, e)
      end
      out
    end

    # A session we have never seen that is already finished and whose process
    # the supervisor has reaped (no pid) has been quiet for at least the
    # supervisor's ~1h idle timeout, which is longer than SETTLE_AFTER. Seed
    # its state_since from started_at so it settles on the first poll instead
    # of squatting in Active for SETTLE_AFTER.
    def self.first_seen_since(session, now_i)
      if session.finished? && !session.alive? && session.started_at
        session.started_at.to_i
      else
        now_i
      end
    end

    # Wake rule: a snoozed session comes back when the timer ran out or when
    # it *becomes* blocked/failed after being snoozed. A session that was
    # already blocked when you snoozed it stays snoozed — that is the point.
    def self.woken?(session, entry, now_i)
      wake_at = entry["wake_at"]
      return false if wake_at.nil?
      return true if session.needs_you? && entry["state_since"].to_i > entry["snoozed_at"].to_i
      return false if wake_at == UNTIL_WOKEN
      wake_at.to_i <= now_i
    end

    def self.snoozed?(session, entry, now_i)
      entry && entry["wake_at"] && !woken?(session, entry, now_i)
    end

    # Hand-settle rule: `x` parks a row in Settled whatever the clock says. It
    # comes back when the session changes state afterwards and is not merely
    # finishing: working again, blocked, or failed. Finishing keeps it parked.
    def self.hand_settled?(session, entry)
      return false unless entry && entry["settled_at"]
      session.finished? || entry["state_since"].to_i <= entry["settled_at"].to_i
    end

    # Acknowledge rule: attaching to a session marks its current state seen, so
    # it drops out of Needs You without being archived to Settled. It comes
    # back the moment the state changes again — same "state_since" test as
    # hand-settle, just routed to Active instead of Settled.
    def self.acknowledged?(session, entry)
      entry && entry["acknowledged_at"] && entry["state_since"].to_i <= entry["acknowledged_at"].to_i
    end

    # Settle rule: done/stopped and quiet for SETTLE_AFTER.
    #
    # A session with a pull request follows the PR instead: it stays up while
    # any PR is open and settles the moment every one is merged or closed. That
    # holds however the session ended its turn, not just when it ran to `done`
    # — opening a PR and asking "anything need changing?" leaves it `blocked`,
    # and merging the PR answers the question, so the row has nothing left to
    # say. A PR whose state nobody knows yet (no gh, offline) is ignored.
    #
    # Two states keep their row whatever the PR says: `working`, which is still
    # going, and `failed`, which is a failure you should see even if the PR it
    # had already opened went on to land.
    def self.settled?(session, entry, now_i)
      return true if hand_settled?(session, entry)
      return false if UNSETTLEABLE.include?(session.effective_state)
      known = session.prs.select(&:known?)
      return known.all?(&:resolved?) if known.any?
      return false unless session.finished?
      since = entry && entry["state_since"]
      return false unless since
      now_i - since.to_i > SETTLE_AFTER
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
    def self.reapable?(session, entry, now_i)
      return false unless session.actionable?
      return false if session.alive?
      return false if UNREAPABLE.include?(session.effective_state)
      return false if entry.nil? || entry["pinned"] || snoozed?(session, entry, now_i)
      since = entry["state_since"]
      !since.nil? && now_i - since.to_i > REAP_AFTER
    end

    # (sessions, entries, now) -> Sections of Rows. Interactive sessions land in
    # Active (they're live) but are never selectable. A pin overrides every
    # other rule except the "you're sitting in this terminal" one, so a pinned
    # session always parks at the top regardless of its state.
    def self.sectionize(sessions, entries, now)
      now_i = now.to_i
      sec = Sections.new(pinned: [], needs_you: [], active: [], snoozed: [], settled: [])
      sessions.each do |s|
        e = s.key && entries[s.key]
        section =
          if s.terminal? then s.needs_you? ? :needs_you : :active # you're in it; never settle or hide it
          elsif e && e["pinned"] then :pinned
          elsif snoozed?(s, e, now_i) then :snoozed
          elsif hand_settled?(s, e) then :settled
          elsif settled?(s, e, now_i) then :settled # a resolved PR outranks Needs You
          elsif s.needs_you? then acknowledged?(s, e) ? :active : :needs_you
          elsif s.finished? then :active
          else :active
          end
        sec[section] << Row.new(session: s, entry: e, section: section)
      end
      sec.pinned.sort_by! { |r| -(r.pinned_at || 0) }
      sec.needs_you.sort_by! { |r| -(r.state_since || 0) }
      sec.active.sort_by! { |r| [r.session.finished? ? 1 : 0, -(r.session.started_at&.to_i || 0)] }
      sec.snoozed.sort_by! { |r| r.parked? ? [1, 0] : [0, r.wake_at.to_i] }
      sec.settled.sort_by! { |r| -(r.state_since || 0) }
      sec
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

    # ----- stateful holder --------------------------------------------------

    DEFAULT_PATH = File.join(Dir.home, ".config", "claude-inbox", "state.json")

    attr_reader :path

    def initialize(path: DEFAULT_PATH, clock: -> { Time.now })
      @path = path
      @clock = clock
      @mutex = Mutex.new
      @sessions = []
      @entries = load
    end

    def update(sessions)
      @mutex.synchronize do
        @sessions = sessions
        @entries = self.class.merge_entries(@entries, sessions, @clock.call)
        save
      end
    end

    def sections(now = @clock.call)
      @mutex.synchronize { self.class.sectionize(@sessions, @entries, now) }
    end

    def sessions = @mutex.synchronize { @sessions.dup }

    def snooze(id, choice)
      now = @clock.call
      edit(id) do |e|
        e["wake_at"] = self.class.snooze_until(choice, now)
        e["snoozed_at"] = now.to_i
      end
    end

    # Also lifts a hand-settle, so `u` undoes `x` as well as `s`.
    def wake(id)
      edit(id) do |e|
        e.delete("wake_at")
        e.delete("snoozed_at")
        e.delete("settled_at")
      end
    end

    def acknowledge(id)
      now = @clock.call
      edit(id) { |e| e["acknowledged_at"] = now.to_i }
    end

    def settle(id)
      now = @clock.call
      edit(id) do |e|
        e["settled_at"] = now.to_i
        e.delete("wake_at")
        e.delete("snoozed_at")
      end
    end

    # Records a reap that `claude rm` refused, so the Reaper backs off instead
    # of shelling out every four seconds for ever at a session whose worktree
    # is never going to let go of its unpushed commits.
    def mark_reap_failed(id, message)
      now = @clock.call
      edit(id) do |e|
        e["reap_failed_at"] = now.to_i
        e["reap_error"] = message.to_s.lines.first&.strip
      end
    end

    def toggle_pin(id)
      now = @clock.call
      edit(id) do |e|
        if e["pinned"]
          e.delete("pinned")
          e.delete("pinned_at")
        else
          e["pinned"] = true
          e["pinned_at"] = now.to_i
        end
      end
    end

    def set_alias(id, name)
      edit(id) { |e| name.to_s.empty? ? e.delete("alias") : e["alias"] = name }
    end

    # Hand-set PR link; empty clears it and the scanned links show again.
    def set_pr(id, url)
      edit(id) { |e| url.to_s.empty? ? e.delete("pr") : e["pr"] = url }
    end

    # session key => url, for PullRequests#enrich.
    def pr_overrides = @mutex.synchronize { @entries.select { |_, e| e["pr"] }.transform_values { |e| e["pr"] } }

    def entry(id) = @mutex.synchronize { @entries[id]&.dup }

    # Forgets a session at once instead of waiting out PRUNE_AFTER, for one
    # the daemon no longer has and that no future poll can bring back.
    def forget(id)
      @mutex.synchronize do
        next unless @entries.delete(id)
        @sessions = @sessions.reject { |s| s.key == id }
        save
      end
    end

    private

    def edit(id)
      @mutex.synchronize do
        e = (@entries[id] ||= {"state_since" => @clock.call.to_i})
        yield e
        save
      end
    end

    def load
      return {} unless @path && File.exist?(@path)
      data = JSON.parse(File.read(@path))
      data["sessions"] || {}
    rescue JSON::ParserError
      {}
    end

    def save
      return unless @path
      JsonFile.write(@path, {"version" => 1, "sessions" => @entries})
    end
  end
end
