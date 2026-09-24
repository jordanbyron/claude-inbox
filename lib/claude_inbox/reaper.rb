# frozen_string_literal: true

require "fileutils"
require_relative "store"
require_relative "agents_client"

module ClaudeInbox
  # Reaps sessions that have sat idle past Store::REAP_AFTER.
  #
  # The one thing in the inbox that destroys anything without being asked
  # first, so the whole of it lives here rather than spread through the poll
  # loop: one public method, and one append-only log that is the last record
  # a session ever existed once `claude rm` has taken its transcript.
  #
  # Unpushed work is safe by construction. `claude rm` refuses a worktree
  # holding commits that aren't pushed and reports a --discard-unpushed token
  # to override it; nothing here ever passes that token, so a refusal is the
  # end of it. Refusals are logged and retried at most daily.
  class Reaper
    RETRY_AFTER = 24 * 3600
    DEFAULT_LOG = File.join(Dir.home, ".config", "claude-inbox", "reaped.log")

    attr_reader :log_path

    def initialize(client, store, log_path: DEFAULT_LOG, enabled: self.class.enabled?)
      @client = client
      @store = store
      @log_path = log_path
      @enabled = enabled
    end

    def self.enabled? = ENV["CLAUDE_INBOX_NO_REAP"].to_s.empty?

    # For --fixture runs and tests: selects nothing, deletes nothing, and
    # needs neither a client nor a store to do it.
    def self.disabled = new(nil, nil, enabled: false)

    # Reaps everything due, returning the keys it actually deleted so the
    # caller can drop those rows before they reach the store. Refusals come
    # back as survivors rather than exceptions: one worktree with unpushed
    # commits must not stop the rest of the sweep.
    #
    # Raises if the log cannot be opened, before anything is deleted. No
    # audit trail, no reaping.
    def sweep(sessions, now)
      now_i = now.to_i
      rows = due_rows(sessions, now_i)
      return [] if rows.empty?
      with_log { |log| rows.filter_map { |row| reap(row, log, now_i) } }
    end

    # Keys `sweep` would go after right now, without touching any of them,
    # so the poller can hand the list over minus these before `claude rm`.
    def due(sessions, now) = due_rows(sessions, now.to_i).map(&:key)

    private

    def due_rows(sessions, now_i)
      return [] unless @enabled
      sessions.map { |s| @store.row(s) }.select { |row| row.reapable?(now_i) && !backing_off?(row, now_i) }
    end

    def backing_off?(row, now_i)
      at = row.reap_failed_at
      !at.nil? && now_i - at.to_i < RETRY_AFTER
    end

    def reap(row, log, now_i)
      @client.rm(row.session.id)
      write(log, row, now_i, "reaped")
      @store.forget(row.key)
      row.key
    rescue AgentsClient::Error => e
      reason = e.message.lines.first.to_s.strip
      @store.mark_reap_failed(row.key, reason)
      write(log, row, now_i, "kept — #{reason}")
      nil
    end

    def write(log, row, now_i, outcome)
      idle_days = (now_i - row.state_since.to_i) / 86_400
      log.puts([
        Time.at(now_i).utc.strftime("%FT%TZ"),
        row.session.id,
        "idle #{idle_days}d",
        row.session.display_name.inspect,
        row.session.cwd,
        outcome
      ].join("  "))
    end

    def with_log
      FileUtils.mkdir_p(File.dirname(@log_path))
      File.open(@log_path, "a") { |f| yield f }
    end
  end
end
