# frozen_string_literal: true

require_relative "records"
require_relative "store/entry"
require_relative "store/row"
require_relative "store/sections"

module ClaudeInbox
  # Snapshot of the last poll plus the per-session entry table, behind a
  # mutex with a JSON file underneath. The values do the thinking: an
  # `Entry` is what is remembered about one session, a `Row` pairs it with
  # the session and carries the triage rules, and `Sections` is one poll
  # sorted into sections. What is left here runs over the whole table.
  class Store
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

    # App and Renderer must agree on this, or j/k lands on rows the frame never painted.
    def self.folded?(name, expanded) = FOLDABLE_SECTIONS.include?(name) && !expanded[name]

    # Fold a fresh poll into the entry table: prune what the daemon has
    # forgotten, then let each session's Entry observe it. Returns a new table.
    def self.merge_entries(entries, sessions, now)
      out = entries.reject { |_, e| Entry.new(e).stale?(now) }.transform_values(&:dup)
      sessions.each do |s|
        next unless s.key
        out[s.key] = Entry.observe(out[s.key], s, now).to_h
      end
      out
    end

    # (sessions, entries, now) -> Sections of Rows, each placed by
    # `Row#section`. Interactive sessions land in Active (they're live) but
    # are never selectable.
    def self.sectionize(sessions, entries, now)
      sec = Sections.new(pinned: [], needs_you: [], active: [], snoozed: [], settled: [])
      sessions.each do |s|
        row = Row.new(session: s, entry: s.key && entries[s.key] && Entry.new(entries[s.key]))
        sec[row.section(now)] << row
      end
      sec.pinned.sort_by! { |r| -(r.pinned_at || 0) }
      sec.needs_you.sort_by! { |r| -(r.state_since || 0) }
      sec.active.sort_by! { |r| [r.session.finished? ? 1 : 0, -(r.session.started_at&.to_i || 0)] }
      sec.snoozed.sort_by! { |r| r.parked? ? [1, 0] : [0, r.wake_at.to_i] }
      sec.settled.sort_by! { |r| -(r.state_since || 0) }
      sec
    end

    DEFAULT_PATH = File.join(Dir.home, ".config", "claude-inbox", "state.json")

    attr_reader :path

    def initialize(path: DEFAULT_PATH, clock: -> { Time.now })
      @path = path
      @clock = clock
      @mutex = Mutex.new
      @sessions = []
      @forgotten = Set.new
      @entries = load
    end

    # A forgotten key still in the list is dropped: `claude rm` has returned
    # but the daemon lists the session for a poll or two more. Once the list
    # stops naming it the tombstone goes, since a short id is never reissued.
    def update(sessions)
      @mutex.synchronize do
        @forgotten &= sessions.map(&:key)
        @sessions = sessions.reject { |s| @forgotten.include?(s.key) }
        @entries = self.class.merge_entries(@entries, @sessions, @clock.call)
        save
      end
    end

    def sections(now = @clock.call)
      @mutex.synchronize { self.class.sectionize(@sessions, @entries, now) }
    end

    def sessions = @mutex.synchronize { @sessions.dup }

    def snooze(id, choice) = edit(id) { |e| e.snooze(choice, @clock.call) }

    def wake(id) = edit(id) { |e| e.wake(@clock.call) }

    def acknowledge(id) = edit(id) { |e| e.acknowledge(@clock.call) }

    def settle(id) = edit(id) { |e| e.settle(@clock.call) }

    def mark_reap_failed(id, message) = edit(id) { |e| e.mark_reap_failed(@clock.call, message) }

    def toggle_pin(id) = edit(id) { |e| e.toggle_pin(@clock.call) }

    def set_alias(id, name) = edit(id) { |e| e.alias = name }

    # The local alias, if one is set; nil means the session's own name shows.
    def alias_for(id) = @mutex.synchronize { @entries[id] && Entry.new(@entries[id]).alias_name }

    def set_pr(id, url) = edit(id) { |e| e.pr = url }

    # The hand-set link, if any; nil means the scanned links are in force.
    def pr_for(id) = @mutex.synchronize { @entries[id] && Entry.new(@entries[id]).pr }

    # session key => url, for PullRequests#enrich.
    def pr_overrides
      @mutex.synchronize { @entries.transform_values { |e| Entry.new(e).pr }.select { |_, url| url } }
    end

    # Pairs a session with its entry for the rules and the Reaper, which read
    # it through the Row's accessors rather than by key.
    def row(session) = Row.new(session: session, entry: session.key && entry(session.key)&.then { |e| Entry.new(e) })

    # The raw hash, for the specs. Nothing in lib/ reads it: callers go
    # through a Row or the readers above.
    def entry(id) = @mutex.synchronize { @entries[id]&.dup }

    # Forgets a session at once instead of waiting out PRUNE_AFTER, for one
    # just handed to `claude rm`, and keeps it hidden until `update` sees the
    # daemon has dropped it too. The tombstone lives in memory only: the gap
    # it bridges is seconds long, and the next update closes it.
    def forget(id)
      @mutex.synchronize do
        @forgotten << id
        @sessions = @sessions.reject { |s| s.key == id }
        save if @entries.delete(id)
      end
    end

    private

    def edit(id)
      @mutex.synchronize do
        yield Entry.new(@entries[id] ||= Entry.blank(@clock.call).to_h)
        save
      end
    end

    def load
      Records.read(@path)["sessions"] || {}
    end

    def save
      return unless @path
      Records.save(@path, {"version" => 1, "sessions" => @entries})
    end
  end
end
