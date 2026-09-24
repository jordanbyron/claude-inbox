# frozen_string_literal: true

require_relative "records"
require_relative "store/entry"
require_relative "store/row"
require_relative "store/selection"
require_relative "store/sections"

module ClaudeInbox
  # The last poll and the per-session entry table, behind a mutex, with
  # state.json underneath.
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

    def self.merge_entries(entries, sessions, now)
      out = entries.reject { |_, e| Entry.new(e).stale?(now) }.transform_values(&:dup)
      sessions.each do |s|
        next unless s.key
        out[s.key] = Entry.observe(out[s.key], s, now).to_h
      end
      out
    end

    def self.row_for(session, entries)
      hash = session.key && entries[session.key]
      Row.new(session: session, entry: hash && Entry.new(hash))
    end

    def self.sectionize(sessions, entries, now)
      sec = Sections.new(pinned: [], needs_you: [], active: [], snoozed: [], settled: [])
      sessions.each do |s|
        row = row_for(s, entries)
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
      @hidden = Set.new
      @forgotten = Set.new
      @entries = load
    end

    # A hidden or forgotten key the daemon has stopped listing is released;
    # one it still lists stays out of sight.
    def update(sessions)
      @mutex.synchronize do
        keys = sessions.map(&:key)
        @hidden &= keys
        @forgotten &= keys
        @sessions = sessions.reject { |s| @hidden.include?(s.key) || @forgotten.include?(s.key) }
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

    def pr_overrides
      @mutex.synchronize { @entries.transform_values { |e| Entry.new(e).pr }.select { |_, url| url } }
    end

    # A copy, not the live entry: the reaper decides a deletion on this row
    # while the UI thread may be editing that entry in place.
    def row(session)
      @mutex.synchronize { self.class.row_for(session, @entries.slice(session.key).transform_values(&:dup)) }
    end

    # The raw hash, for the specs; nothing in lib/ reads it.
    def entry(id) = @mutex.synchronize { @entries[id]&.dup }

    # Keeps rows out of sight while `claude rm` is on them, so none paints
    # mid-delete; `release` brings back one `rm` refused. Memory only.
    def hide(keys)
      @mutex.synchronize do
        @hidden.merge(keys)
        @sessions = @sessions.reject { |s| keys.include?(s.key) }
      end
    end

    def release(keys) = @mutex.synchronize { @hidden.subtract(keys) }

    # A session `claude rm` has taken stays hidden until `update` sees the
    # daemon has dropped it too. Kept apart from `hide` so a `release` on the
    # same poll cannot bring back what the user deleted.
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
