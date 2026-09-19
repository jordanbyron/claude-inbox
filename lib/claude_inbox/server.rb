# frozen_string_literal: true

require "json"
require_relative "agents_client"
require_relative "logs"
require_relative "poller"
require_relative "pull_requests"
require_relative "settings"
require_relative "slash_commands"
require_relative "store"

module ClaudeInbox
  # The backend behind a screen that is not App: everything App does below
  # the terminal, spoken as one JSON object per line over a pipe. Sections
  # go out after every poll and every edit, already sorted by the Store's
  # rules, so the screen never has to know why a row is where it is; commands
  # come in as {"cmd": ..., ...} and change the store, the poller or the
  # daemon. Attaching is the one thing that needs the tty and so cannot
  # travel over the pipe: the screen pauses the poller, runs
  # `bin/claude-inbox-server attach <id>` on the tty itself, then resumes.
  class Server
    def initialize(client: AgentsClient.new, store: Store.new, pull_requests: PullRequests.new, jobs_dir: JobState::DEFAULT_DIR,
      reaper: Reaper.disabled, input: $stdin, out: $stdout, clock: -> { Time.now })
      @client = client
      @store = store
      @out = out
      @input = input
      @clock = clock
      @queue = Queue.new
      @poller = Poller.new(client: client, store: store, pull_requests: pull_requests, jobs_dir: jobs_dir,
        reaper: reaper, queue: @queue)
      @write = Mutex.new
      @polled = false
    end

    def run
      @poller.start
      @logs = Logs.new(@client, @queue)
      reader = Thread.new { read_commands }
      loop do
        drain(@queue.pop(timeout: Logs::DEBOUNCE))
        @logs.tick
      end
    ensure
      reader&.kill
      @poller.stop
      @logs&.stop
    end

    def emit(event, **fields)
      line = JSON.generate({"event" => event}.merge(fields.transform_keys(&:to_s)))
      @write.synchronize do
        @out.puts line
        @out.flush
      end
    end

    def publish
      now = @clock.call
      sections = @store.sections(now)
      emit(:sections, now: now.to_i, polled: @polled, sections: Store::SECTIONS.map { |name|
        {"name" => name.to_s, "rows" => sections[name].map { |row| self.class.row_json(row, now) }}
      })
    end

    # The facts of a row, none of the styling: the Store has already said
    # which section it sits in.
    def self.row_json(row, now)
      s = row.session
      {
        "key" => row.key, "id" => s.id, "session_id" => s.session_id,
        "selectable" => row.selectable?, "label" => row.label, "aliased" => !row.alias_name.nil?,
        "cwd" => s.cwd, "project" => s.project, "pid" => s.pid,
        "state" => s.effective_state, "raw_state" => s.state, "status" => s.status, "waiting_for" => s.waiting_for,
        "interactive" => s.interactive?, "remote" => s.remote?, "terminal" => s.terminal?,
        "actionable" => s.actionable?, "alive" => s.alive?, "finished" => s.finished?,
        "waiting_on_work" => s.waiting_on_work?, "in_flight" => s.job_state&.in_flight_label,
        "color" => s.color, "started_at" => s.started_at&.to_i,
        "state_since" => row.state_since, "wake_at" => row.parked? ? nil : row.wake_at, "parked" => row.parked? || false,
        "pinned" => row.pinned? || false,
        "prs" => s.prs.map { |pr| {"short" => pr.short, "url" => pr.url, "state" => pr.state} }
      }
    end

    def read_commands
      @input.each_line do |line|
        line = line.strip
        next if line.empty?
        @queue << [:command, JSON.parse(line)]
      rescue JSON::ParserError => e
        emit(:error, message: "bad command: #{e.message}")
      end
      @queue << [:eof]
    end

    def drain(message)
      return unless message
      kind, *rest = message
      case kind
      when :sessions
        @store.update(rest[0])
        @polled = true
        emit(:polled, at: @clock.call.to_i)
        publish
      when :error then emit(:error, message: rest[0])
      when :notice then emit(:notice, message: rest[0])
      when :peek then emit(:peek, id: rest[0], lines: rest[1])
      when :command then command(rest[0])
      when :eof then raise SystemExit
      end
    end

    def command(c)
      id = c["id"]
      case c["cmd"]
      when "snooze" then @store.snooze(id, c["choice"].to_sym)
      when "wake" then @store.wake(id)
      when "toggle_pin" then @store.toggle_pin(id)
      when "settle" then @store.settle(id)
      when "acknowledge" then @store.acknowledge(id)
      when "set_alias" then @store.set_alias(id, c["value"].to_s)
      when "set_pr"
        url = c["value"].to_s
        return emit(:error, message: "that's not a github.com pull request url") unless url.empty? || PullRequests.valid_url?(url)
        @store.set_pr(id, url)
        @poller.soon
      when "refresh" then @poller.soon
      when "pause" then @poller.pause
      when "resume" then @poller.resume
      when "peek" then @logs.want(id)
      when "stop" then in_background { @client.stop(id) }
      when "rm"
        in_background do
          @client.rm(id)
          @store.forget(id)
          emit(:notice, message: "deleted #{id}")
        end
      when "spawn" then spawn(c)
      when "defaults" then emit(:defaults, cwd: c["cwd"], **Settings.defaults(c["cwd"].to_s).to_h)
      when "commands"
        emit(:commands, cwd: c["cwd"], commands: SlashCommands.list(cwd: c["cwd"].to_s).map { |k| {"name" => k.to_s, "description" => k.description} })
      when "quit" then raise SystemExit
      else return emit(:error, message: "unknown command #{c["cmd"].inspect}")
      end
      publish
    end

    def spawn(c)
      in_background do
        id = @client.spawn(prompt: c["prompt"].to_s, cwd: c["cwd"].to_s, name: c["name"],
          model: c["model"], effort: c["effort"], permission_mode: c["permission_mode"], worktree: c["worktree"] == true)
        emit(:spawned, id: id, attach: c["attach"] == true)
      end
    end

    def in_background
      Thread.new do
        yield
        @poller.soon
      rescue => e
        emit(:error, message: e.message)
      end
    end
  end
end
