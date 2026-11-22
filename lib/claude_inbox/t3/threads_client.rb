# frozen_string_literal: true

require "json"
require "securerandom"
require "time"
require "tmpdir"
require_relative "../records"
require_relative "../session_request"
require_relative "../session"
require_relative "../store"
require_relative "../subprocess"
require_relative "server"
require_relative "workspace"

module ClaudeInbox
  module T3
    # The T3 Code adapter. Swap in FixtureClient for tests.
    class ThreadsClient
      ACTIONS = %i[attach stop delete].freeze

      HARNESS_BY_DRIVER = {"codex" => :codex, "antigravity" => :antigravity, "claudeAgent" => :claude}.freeze

      LIVE = %w[preparing queued starting running waiting].freeze
      STATES = {"failed" => "error", "completed" => "done"}.freeze
      LINES = {"permission" => "waiting on approval", "question" => "waiting on input"}.freeze

      STARTS = %i[codex antigravity].freeze
      T3_ONLY = %i[antigravity].freeze

      RUNTIME_MODES = %w[approval-required auto-accept-edits auto full-access].freeze
      # T3 wants a mode on every launch; this is its own default.
      DEFAULT_RUNTIME = "full-access"
      DEFAULT = "default"
      TITLE_MAX = 80

      # Provider status and models change rarely, and the answer is 200KB.
      CONFIG_EVERY = 60

      def initialize(server: Server.new, tria: "tria", out: $stdout, clock: -> { Time.now })
        @server = server
        @tria = tria
        @out = out
        @clock = clock
        @config = nil
        @config_at = nil
      end

      def pulse = nil

      # T3 never forgets a thread either, so the list stops where Codex's does.
      def list
        shell = @server.shell or return forget_config
        read_config
        horizon = @clock.call - Store::REAP_AFTER
        self.class.sessions(shell, drivers).reject { |s| s.last_message_at && s.last_message_at < horizon }
      end

      def attach(session)
        handoff = File.join(Dir.tmpdir, "claude-inbox-handoff-#{SecureRandom.hex(8)}.json")
        here = (session.cwd && File.directory?(session.cwd)) ? {chdir: session.cwd} : {}
        ran = system(*Subprocess.command(@tria, "attach", session.id, "--handoff", handoff, **here))
        @out.puts "#{@tria} would not start" if ran.nil?
        next_row = Records.read(handoff)["attach"]
        next_row || ran == true
      ensure
        File.delete(handoff) if File.exist?(handoff)
      end

      # The Session does not carry the run's id, so the shell is read for it.
      def stop(session)
        run = @server.shell!["threads"]&.find { |t| t["id"] == session.id }&.dig("activeRunId") or return false
        dispatch("run.interrupt", threadId: session.id, runId: run)
        true
      end

      def rm(session) = dispatch("thread.delete", threadId: session.id)

      # A harness only T3 runs is there as nil while it can't, so the form can say so.
      def choices
        return {} unless @server.installed?
        ready = providers.select { |p| p["enabled"] && p["status"] == "ready" }
        offered = STARTS.filter_map do |harness|
          provider = ready.find { |p| HARNESS_BY_DRIVER[p["driver"]] == harness }
          [harness, provider && choices_for(provider)] if provider || T3_ONLY.include?(harness)
        end
        offered.to_h
      end

      def spawn(harness:, prompt:, cwd:, model: nil, effort: nil, permission_mode: nil, images: [])
        provider = providers.find { |p| HARNESS_BY_DRIVER[p["driver"]] == harness && p["status"] == "ready" } or
          raise Server::Error, "T3 Code has no #{harness} ready"
        text = images.empty? ? prompt : SessionRequest.attach(prompt, images)
        result = @server.call!("orchestration.launchThread", {
          commandId: SecureRandom.uuid, creationSource: "web", **Workspace.new(@server, cwd).launch,
          title: title(prompt), generateTitle: true,
          modelSelection: model_selection(provider, model, effort),
          runtimeMode: permission_mode || DEFAULT_RUNTIME, interactionMode: "default",
          initialMessage: {messageId: SecureRandom.uuid, text: text, attachments: []}
        })
        result["threadId"]
      end

      def self.sessions(shell, drivers = {})
        projects = (shell["projects"] || []).to_h { |p| [p["id"], p] }
        (shell["threads"] || [])
          .select { |t| own?(t) }
          .map { |t| session(t, projects[t["projectId"]], drivers) }
          .sort_by { |s| -s.last_message_at.to_f }
      end

      def self.session(thread, project = nil, drivers = {})
        state, blocked = state(thread)
        instance = thread["providerInstanceId"] || thread.dig("modelSelection", "instanceId")
        driver = drivers.fetch(instance, instance)
        Session.new(
          harness: :t3,
          provider: HARNESS_BY_DRIVER.fetch(driver) { driver.to_s.to_sym },
          actions: ACTIONS,
          id: thread["id"],
          kind: "background",
          cwd: thread["worktreePath"] || project&.dig("workspaceRoot"),
          name: squish(thread["title"]),
          state: state,
          line: LINES[blocked] || (squish(thread["lastError"]) if state == "error"),
          started_at: time(thread["createdAt"]),
          last_message_at: time(thread["updatedAt"]),
          branch: thread["branch"],
          origin_url: project&.dig("repositoryIdentity", "locator", "remoteUrl"),
          pr_urls: (thread["pullRequests"] || []).filter_map { |pr| pr["url"] }
        )
      end

      # An imported thread is a Claude Code or Codex session its own adapter
      # lists; a sub-agent's parent stands for it.
      def self.own?(thread)
        !thread["id"].start_with?("import:") && !thread["deletedAt"] && thread.dig("lineage", "relationshipToParent") != "subagent"
      end

      def self.state(thread)
        request = thread["pendingRuntimeRequest"]
        if blocking?(request)
          ["blocked", (request["kind"] == "user_input") ? "question" : "permission"]
        elsif LIVE.include?(thread["status"]) || thread["activeRunId"]
          ["working"]
        else
          [STATES.fetch(thread["status"], "idle")]
        end
      end

      # An async question leaves the run working past it.
      def self.blocking?(request) = request && request["blocking"] != false

      def self.squish(text)
        words = text.to_s.split.join(" ")
        words unless words.empty?
      end

      def self.time(iso) = iso && Time.iso8601(iso)

      private_class_method :own?, :blocking?, :squish, :time

      private

      def dispatch(type, **fields) = @server.call!("orchestration.dispatchCommand", {type: type, commandId: SecureRandom.uuid, **fields})

      def forget_config
        @config = @config_at = nil
        []
      end

      def read_config
        return if @config_at && @clock.call - @config_at < CONFIG_EVERY
        @config = @server.call("server.getConfig") || @config
        @config_at = @clock.call
      end

      def providers = @config&.dig("providers") || []

      def choices_for(provider)
        models = provider["models"] || []
        efforts = models.flat_map { |m| reasoning(m)&.dig("options")&.map { |o| o["id"] } || [] }.uniq
        modes = provider["supportedRuntimeModes"] || RUNTIME_MODES
        {model: [DEFAULT, *models.map { |m| m["slug"] }], effort: [DEFAULT, *efforts], permission_mode: [DEFAULT, *modes], default: "t3 default"}
      end

      # Each driver names its reasoning option its own way: reasoningEffort, effort, thought_level.
      def reasoning(model)
        descriptors = model.dig("capabilities", "optionDescriptors") || []
        descriptors.find { |d| d["role"] == "reasoning" } || descriptors.find { |d| d["type"] == "select" && d["id"].match?(/effort|reason|thought/i) }
      end

      def model_selection(provider, slug, effort)
        models = provider["models"] || []
        model = models.find { |m| m["slug"] == slug } || models.find { |m| m["isDefault"] } || models.first or
          raise Server::Error, "T3 Code offers no #{provider["instanceId"]} model"
        option = reasoning(model) if effort
        {instanceId: provider["instanceId"], model: model["slug"], options: option ? [{id: option["id"], value: effort}] : []}
      end

      def title(prompt)
        line = prompt.lines.map(&:strip).find { |l| !l.empty? }.to_s
        (line.length > TITLE_MAX) ? "#{line[0, TITLE_MAX - 1].rstrip}…" : line
      end

      def drivers = providers.to_h { |p| [p["instanceId"], p["driver"]] }
    end

    # Serves a committed shell snapshot instead of the server; no file, no threads.
    class FixtureClient < ThreadsClient
      def initialize(path)
        @path = path
      end

      def list = File.exist?(@path) ? self.class.sessions(JSON.parse(File.read(@path))) : []

      # Stand-in child, as the Claude fixture's attach is.
      def attach(session) = system("sh", "-c", "printf 'fake tria attach %s\\npress enter to detach: ' \"$1\"; read -r _", "attach", session.id)

      def stop(_session) = true

      def rm(_session) = nil
    end
  end
end
