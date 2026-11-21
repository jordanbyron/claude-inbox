# frozen_string_literal: true

require "json"
require "securerandom"
require "time"
require "tmpdir"
require "uri"
require_relative "../debug"
require_relative "../harnesses"
require_relative "../session"
require_relative "../store"
require_relative "../subprocess"

module ClaudeInbox
  module Antigravity
    # The Antigravity (`agy`) adapter: reads conversations from agy's SQLite
    # summaries database and presence locks, and attaches, stops and starts
    # them through `agy`. Swap in FixtureClient for tests.
    class ConversationsClient
      # No delete: agy has no CLI command to remove a conversation, and the
      # inbox does not delete agy's files itself.
      ACTIONS = %i[attach stop].freeze

      DEFAULT_DIR = File.join(Dir.home, ".gemini", "antigravity-cli")
      RUNNING = "CASCADE_RUN_STATUS_RUNNING"
      HEADLESS_FLAGS = %w[-p --print --prompt].freeze
      WATCH_INTERVAL = 0.05
      SPAWN_TIMEOUT = 30

      SQL = <<~SQL.tr("\n", " ").strip
        SELECT conversation_id, title, preview, last_modified_time,
               last_user_input_time, workspace_uris, status
        FROM conversation_summaries
        WHERE COALESCE(parent_conversation_id, '') = ''
        ORDER BY last_modified_time DESC
      SQL

      def initialize(dir: DEFAULT_DIR, bin: "agy", sqlite: "sqlite3", clock: -> { Time.now }, spawn_timeout: SPAWN_TIMEOUT)
        @dir = dir
        @db_path = File.join(dir, "conversation_summaries.db")
        @bin = bin
        @sqlite = sqlite
        @clock = clock
        @spawn_timeout = spawn_timeout
      end

      def pulse
        [@db_path, "#{@db_path}-wal"].map { |path| stat_stamp(path) }
      end

      # => Array<Session>, newest first; empty without a database or sqlite3.
      def list
        horizon = @clock.call - Store::REAP_AFTER
        sessions = query_rows
          .filter_map { |row| build_session(row) if row["parent_conversation_id"].to_s.empty? }
          .reject { |s| s.last_message_at && s.last_message_at < horizon }
          .sort_by { |s| -(s.last_message_at&.to_f || 0) }
        @choices ||= read_choices
        sessions
      end

      # The block, polled alongside, ends the attach early when it answers true.
      def attach(session, &stop)
        here = (session.cwd && File.directory?(session.cwd)) ? {chdir: session.cwd} : {}
        pid = Process.spawn(*Subprocess.command(@bin, "--conversation", session.id, **here))
        stopped = false
        watchdog = stop && Thread.new do
          watch_stop(pid) do
            next false unless stop.call
            stopped = true
          end
        end
        _, status = Process.wait2(pid)
        stopped || status.success? || !status.exited?
      rescue Errno::ENOENT => e
        warn e.message
        false
      ensure
        watchdog&.kill
      end

      def stop(session)
        return false unless locked?(session.id)
        pids = holder_pids(session.id)
        return false if pids.empty?
        Process.kill("INT", *pids)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM => e
        raise Harnesses::Error, "could not stop #{session.id}: #{e.message}"
      end

      def rm(_session)
        raise Harnesses::Error, "antigravity conversations cannot be deleted from outside"
      end

      # Filled during list off the UI thread so n never waits on `agy models`.
      def choices = @choices || {}

      # Output goes to an unlinked file rather than a pipe so the detached run
      # can neither block nor get SIGPIPE once the inbox stops reading.
      def spawn(prompt:, cwd:, model: nil)
        argv = [@bin, "-p", prompt, *(["--model", model] if model), "--output-format", "stream-json"]
        out_r, out_w = unlinked_pair
        err_r, err_w = unlinked_pair
        pid = nil
        reaped = false
        begin
          pid = begin
            Process.spawn(*Subprocess.command(*argv, chdir: cwd, in: File::NULL, out: out_w, err: err_w, pgroup: true))
          rescue SystemCallError => e
            raise Harnesses::Error, "agy -p failed: #{e.message}"
          end
          out_w.close
          err_w.close
          wait_for_init(pid, out_r, err_r) { reaped = true }
        rescue
          Process.detach(pid) if pid && !reaped
          raise
        ensure
          [out_r, out_w, err_r, err_w].each { |io| io&.close unless io&.closed? }
        end
      end

      def self.sessions(rows)
        (rows || []).filter_map do |row|
          next unless row["parent_conversation_id"].to_s.empty?
          session(row, working: row["status"] == RUNNING)
        end
      end

      def self.session(row, working: false, fallback_time: nil)
        preview = squish(row["preview"])
        modified = time(row["last_modified_time"]) || fallback_time
        Session.new(
          harness: :antigravity,
          actions: ACTIONS,
          id: row["conversation_id"],
          kind: "background",
          cwd: workspace_cwd(row["workspace_uris"]),
          name: squish(row["title"]) || preview,
          intent: preview,
          state: working ? "working" : "idle",
          started_at: time(row["last_user_input_time"]) || modified,
          last_message_at: modified
        )
      end

      def self.headless?(cmd)
        cmd.to_s.split.drop(1).any? { |arg| HEADLESS_FLAGS.include?(arg.split("=", 2).first) }
      end

      # `agy models` prints `id<TAB>label` lines after a status line, and an
      # `Error:` line with no models when signed out.
      def self.parse_models(output)
        output.to_s.lines.filter_map do |line|
          id, label = line.chomp.split("\t", 2)
          next unless label
          id = id.strip
          id if !id.empty? && !id.match?(/\s/)
        end
      end

      def self.workspace_cwd(raw)
        uris = JSON.parse(raw.to_s)
        return nil unless uris.is_a?(Array)
        uri = uris.find { |u| u.is_a?(String) && u.start_with?("file://") } or return nil
        path = uri.sub(%r{\Afile://(?:localhost)?}, "")
        URI.decode_uri_component(path)
      rescue JSON::ParserError, ArgumentError
        nil
      end

      def self.immutable_uri(path)
        "file:#{path.gsub("%", "%25").gsub("?", "%3F").gsub("#", "%23")}?immutable=1"
      end

      def self.squish(text)
        words = text.to_s.split.join(" ")
        words unless words.empty?
      end

      # Go's zero time.Time (year 1) stands in for an unwritten timestamp in
      # fresh placeholder rows (docs/cli-quirks.md).
      def self.time(value)
        return nil if value.nil? || value.to_s.strip.empty?
        t = Time.parse(value.to_s)
        t if t.year > 1
      rescue ArgumentError
        nil
      end

      private_class_method :squish, :time

      private

      def build_session(row)
        id = row["conversation_id"]
        self.class.session(row, working: working?(row), fallback_time: lock_mtime(id))
      end

      def lock_mtime(id)
        File.mtime(lock_path(id))
      rescue SystemCallError
        nil
      end

      # A headless run can read IDLE mid-turn while holding its lock and exits
      # when its turn ends; an interactive one holds the lock at its prompt
      # (docs/cli-quirks.md).
      def working?(row)
        id = row["conversation_id"]
        return false unless locked?(id)
        return true if row["status"] == RUNNING
        pids = holder_pids(id)
        return false if pids.empty?
        commands_for(pids).any? { |cmd| self.class.headless?(cmd) }
      end

      def holder_pids(id)
        r = Subprocess.capture("lsof", "-t", lock_path(id))
        return [] unless r.success?
        r.out.lines.filter_map { |line| Integer(line.strip, exception: false) }.uniq
      end

      def commands_for(pids)
        r = Subprocess.capture("ps", "-o", "command=", "-p", pids.join(","))
        r.success? ? r.out.lines : []
      end

      def query_rows
        return [] unless File.exist?(@db_path)
        r = Subprocess.capture(@sqlite, "-readonly", "-json", @db_path, SQL)
        # Without a live agy process holding the WAL open, -readonly fails with
        # SQLITE_CANTOPEN (14); immutable=1 reads the main file without creating
        # -wal/-shm in agy's directory (docs/cli-quirks.md).
        if !r.success? && r.status.exitstatus != 127
          r = Subprocess.capture(@sqlite, "-json", self.class.immutable_uri(@db_path), SQL)
        end
        unless r.success?
          Debug.log("antigravity sqlite3: #{r.err.strip}")
          return []
        end
        r.out.strip.empty? ? [] : JSON.parse(r.out)
      rescue JSON::ParserError => e
        Debug.log("antigravity sqlite3 json: #{e.message}")
        []
      end

      def read_choices
        r = Subprocess.capture(@bin, "models")
        return {} unless r.success?
        models = self.class.parse_models(r.out)
        models.empty? ? {} : {model: ["default", *models]}
      end

      def lock_path(id) = File.join(@dir, "presence", "#{id}.lock")

      def locked?(id)
        path = lock_path(id)
        return false unless File.exist?(path)
        File.open(path, File::RDONLY) do |f|
          if f.flock(File::LOCK_EX | File::LOCK_NB)
            f.flock(File::LOCK_UN)
            false
          else
            true
          end
        end
      rescue SystemCallError
        false
      end

      def stat_stamp(path)
        st = File.stat(path)
        [st.mtime, st.size]
      rescue SystemCallError
        nil
      end

      def unlinked_pair
        path = File.join(Dir.tmpdir, "claude-inbox-agy-#{SecureRandom.hex(8)}")
        writer = File.open(path, File::CREAT | File::EXCL | File::WRONLY, 0o600)
        reader = File.open(path, File::RDONLY)
        [reader, writer]
      rescue
        writer&.close
        raise
      ensure
        File.unlink(path) if path && File.exist?(path)
      end

      def wait_for_init(pid, out_r, err_r)
        buf = +""
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @spawn_timeout
        loop do
          if (id = take_init(out_r, buf))
            Process.detach(pid)
            yield
            return id
          end
          if Process.waitpid2(pid, Process::WNOHANG)
            yield
            id = take_init(out_r, buf, drain: true)
            return id if id
            detail = [err_r.read, buf].map(&:strip).reject(&:empty?).first || "exited before init"
            raise Harnesses::Error, "agy -p failed: #{detail}"
          end
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            stop_child(pid)
            yield
            raise Harnesses::Error, "agy -p timed out waiting for conversation id"
          end
          sleep WATCH_INTERVAL
        end
      end

      def take_init(io, buf, drain: false)
        while (chunk = io.read(65_536))
          buf << chunk
        end
        while (nl = buf.index("\n"))
          id = init_id(buf.slice!(0..nl))
          return id if id
        end
        init_id(buf) if drain && !buf.empty?
      end

      def init_id(line)
        event = JSON.parse(line)
        return unless event.is_a?(Hash)
        if event["event"] == "init"
          id = event["conversation_id"]
          id if id.is_a?(String) && !id.empty?
        elsif event["event"] == "result" && event["status"] == "ERROR"
          raise Harnesses::Error, "agy -p failed: #{event["error"] || "unknown error"}"
        end
      rescue JSON::ParserError
        nil
      end

      def watch_stop(pid)
        loop do
          sleep WATCH_INTERVAL
          next unless yield
          terminate(pid)
          break
        end
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end

      def terminate(pid)
        Process.kill("TERM", pid)
        10.times do
          sleep 0.1
          Process.kill(0, pid)
        end
        Process.kill("KILL", pid)
      rescue Errno::ESRCH
        nil
      end

      def stop_child(pid)
        terminate(pid)
        Process.waitpid(pid)
      rescue Errno::ECHILD
        nil
      end
    end

    # Serves committed `conversation_summaries` JSON rows instead of SQLite;
    # no file, no conversations.
    class FixtureClient < ConversationsClient
      def initialize(path)
        @path = path
      end

      def pulse = nil

      def list = File.exist?(@path) ? self.class.sessions(JSON.parse(File.read(@path))) : []

      def attach(session) = system("sh", "-c", "printf 'fake agy --conversation %s\\npress enter to detach: ' \"$1\"; read -r _", "attach", session.id)

      def stop(_session) = true

      def choices = {model: %w[default gemini-4-neon-high gemini-4-neon-low]}

      def spawn(**)
        sleep 0.5
        "b42411c1-f1e5-47d4-bbce-a236016bc3b8"
      end
    end
  end
end
