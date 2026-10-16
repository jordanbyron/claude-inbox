# frozen_string_literal: true

require_relative "notifier_app"
require_relative "subprocess"

module ClaudeInbox
  # Desktop notifications for --notify: a row that came to need you or a
  # background session that finished between one poll and the next, said
  # through terminal-notifier. `diff` decides, `deliver` says it.
  class Notifier
    MISSING = "terminal-notifier not found"
    # The sections a row is heard from: not snoozed, not settled.
    WATCHED = %i[pinned needs_you active].freeze

    # Marks the one that wants you, so it stands out from a finished one.
    BADGE = {"needs you" => "🔴 "}.freeze

    Notification = Data.define(:key, :kind, :label, :line) do
      def message = "#{BADGE[kind]}#{line ? "#{kind}: #{line}" : kind}"
    end

    def self.disabled = new(enabled: false)

    # The notifications `after` earns over `before`, two Sections of the same
    # moment: one per row whose alert changed, with the row's own line. A row
    # that only changed section has nothing new to say: the first gh refresh
    # un-settles one whose open PR the cache did not know, and a snoozed
    # row's timer runs out.
    def self.diff(before, after)
      was = alerts(before)
      rows(after).filter_map do |row|
        kind = alert(row)
        Notification.new(key: row.key, kind: kind, label: row.label, line: row.session.summary) if kind && was[row.key] != kind
      end
    end

    # key => "needs you", "finished" or nil, over every row, snoozed and settled too.
    def self.alerts(sections) = sections.all.to_h { |row| [row.key, alert(row)] }

    def self.rows(sections) = WATCHED.flat_map { |name| sections[name] }

    # Interactive sessions stay quiet: you are in that terminal.
    def self.alert(row)
      return nil unless row.session.background?
      if row.session.needs_you? then "needs you" unless row.acknowledged?
      elsif row.session.effective_state == "done" then "finished"
      end
    end

    def initialize(app: NotifierApp.new, run: Subprocess.method(:capture), enabled: true)
      @app = app
      @run = run
      @enabled = enabled
      @primed = false
      @given_up = false
    end

    # Sends what `diff` finds, off the calling thread, and yields the one
    # notice a binary that will not run earns. The first call only primes,
    # and readies the app: every row already blocked at startup would
    # otherwise fire at once.
    def deliver(before, after, &notice)
      return unless @enabled
      return prime unless @primed
      notifications = self.class.diff(before, after)
      return if notifications.empty? || @given_up
      Thread.new do
        notifications.each do |n|
          r = @run.call(*@app.command, "-title", n.label, "-message", n.message, "-group", n.key)
          next if r.success?
          @given_up = true
          notice&.call((r.status.exitstatus == 127) ? MISSING : "terminal-notifier: #{r.err.lines.first.to_s.strip}")
          break
        end
      end
    end

    private

    def prime
      @primed = true
      Thread.new { @app.prepare }
    end
  end
end
