# frozen_string_literal: true

require "optparse"
require "tmpdir"
require_relative "app"
require_relative "codex/threads_client"
require_relative "harnesses"
require_relative "config"
require_relative "headless"
require_relative "mod"
require_relative "notifier"
require_relative "updater"
require_relative "writer_lock"

module ClaudeInbox
  # What `claude-inbox` does with its arguments: install the pane, update
  # claude-inbox, or launch the inbox. `run` is true when it succeeded.
  class CLI
    USAGE = <<~USAGE
      Usage: claude-inbox [options]
             claude-inbox install [--force]
             claude-inbox update
    USAGE

    # `lock` stands in for the writer lock a live launch takes.
    def initialize(argv, env: ENV, config: Config::PATH, lock: nil, out: $stdout)
      @argv = argv
      @env = env
      @config = config
      @lock = lock
      @out = out
    end

    def run
      case @argv.first
      when "install" then install
      when "update" then update
      else launch
      end
    end

    # The launch flags, the config file's before the typed ones. A fixture
    # run takes the listen flags, for trying the API with curl, but not the
    # environment or the config file, which are for the real inbox.
    def options
      @options ||= begin
        typed = parse(@argv)
        options = typed[:fixture] ? typed : parse(Config.argv(@argv, path: @config))
        env = typed[:fixture] ? {} : @env
        options.merge(listen: Remote::Listener.options(env, flag: options[:listen], modes: options[:allow_modes]))
      end
    rescue OptionParser::ParseError, ArgumentError => e
      abort "claude-inbox: #{e.message}"
    end

    # The keywords App is built with. A live launch takes the writer lock
    # here: the first inbox you can see is the snapshot's writer, and a
    # second one reads along, writing and deleting nothing.
    def app_options
      opts = options[:fixture] ? fixture_options : live_options
      opts[:color] = options[:color]
      opts[:notifier] = notifier
      return opts if options[:fixture] || writer_lock.take(role: "inbox")
      opts.merge(store: new_store(writable: false, relay: Actions.new), reaper: Reaper.disabled,
        snapshot: Snapshot.disabled, actions: Actions.disabled, pane_offer: Mod::Offer.disabled, notifier: Notifier.disabled)
    end

    private

    def install
      force = false
      subcommand("install") { |p| p.on("--force", "Replace any other copy of the pane") { force = true } }
      begin
        installed = Mod.install(force: force)
      rescue JSON::ParserError
        abort "claude-inbox: ~/.claude/settings.json is not valid JSON, so it was left alone"
      end
      installed.removed.each { |dir| @out.puts "Removed #{dir} from ~/.claude/settings.json." }
      @out.puts "The pane now runs #{Mod::COMMAND || "claude-inbox from your PATH"}." if installed.command_set
      @out.puts(installed.added ? "Added the pane to ~/.claude/settings.json. New Claude Code sessions load it; /inbox opens it." :
        "The pane is already in ~/.claude/settings.json.")
      true
    end

    def update
      subcommand("update")
      updater = Updater.new
      begin
        update = updater.check(force: true)
      rescue Updater::Error => e
        abort "claude-inbox: #{e.message}"
      end
      unless update
        @out.puts((updater.kind == :gem) ? "claude-inbox #{VERSION} is the latest release." : "main is up to date.")
        return true
      end
      @out.puts update.installing
      applied = updater.apply
      abort "claude-inbox: #{applied.output.strip}" unless applied.success?
      @out.puts((update.kind == :gem) ? "Installed claude-inbox #{update.latest}." : "main is at #{update.latest}.")
      true
    end

    def launch
      options
      # Crash traces go here instead of the alt screen when set.
      $stderr.reopen(@env["CLAUDE_INBOX_STDERR"], "a") if @env["CLAUDE_INBOX_STDERR"]
      return headless if options[:headless]
      auto_update if options[:auto_update]
      # So the pane settings.json names is the installed version's, after a gem update too.
      Mod.link unless options[:fixture]
      App.new(**app_options).run
      true
    end

    def headless
      abort "claude-inbox: --headless takes no --fixture" if options[:fixture]
      Headless.new(client: live_client, store: new_store, updater: updater, notifier: notifier).run
    end

    # Only what a check within the day already found: a cold launch never waits
    # on the network. The relaunch is the new version's launch; a failure leaves
    # this one to start as usual.
    def auto_update
      return unless (update = updater&.cached)
      @out.puts update.installing
      applied = updater.apply
      applied.success? ? updater.relaunch(@argv) : warn("claude-inbox: #{applied.output.strip}")
    end

    def fixture_options
      fixtures = File.dirname(options[:fixture])
      # Its own token, lock and images, so a test inbox can neither rotate the
      # token phones are paired with nor hold the real inbox's lock.
      dir = File.join(Dir.tmpdir, "claude-inbox-fixture")
      {client: Harnesses.new(claude: Claude::FixtureClient.new(options[:fixture]), codex: Codex::FixtureClient.new(File.join(fixtures, "codex-threads.json"))),
       store: new_store(path: nil),
       pull_requests: PullRequests.new(cache_path: File.join(fixtures, "gh-pr-status-cache.json"), resolved_path: nil, gh: nil),
       listen: options[:listen]&.merge(fixture: true, pairing: Remote::Pairing.new(path: File.join(dir, "listen.json")),
         lock_path: File.join(dir, "listen.lock"), images_dir: File.join(dir, "images"))}
    end

    # The only place the reaper is armed, and only with --reap: deleting
    # sessions is opt-in. Everything else — tests, --fixture, anything
    # embedding App — gets one that deletes nothing. The listener, likewise,
    # comes only from here, and only when asked for.
    def live_options
      client = live_client
      store = new_store
      {client: client, store: store, reaper: options[:reap] ? Reaper.new(client, store) : Reaper.disabled,
       snapshot: Snapshot.new, switch: Switch.new, actions: Actions.new, pane_offer: Mod::Offer.new,
       listen: options[:listen], updater: updater,
       # The typed arguments, not the config's: a relaunch reads the config again.
       argv: @argv}
    end

    def live_client = Harnesses.new(claude: Claude::AgentsClient.new, codex: Codex::ThreadsClient.new)

    def updater
      @updater ||= Updater.new if options[:update_check] && !options[:fixture]
    end

    # The sectioning flags apply to every store a launch builds.
    def new_store(**opts) = Store.new(sort: options[:sort], fold_working: options[:fold_working], **opts)

    def notifier = options[:notify] ? Notifier.new : Notifier.disabled

    # Held for the life of this process by this reference.
    def writer_lock = (@lock ||= WriterLock.new)

    def parse(argv)
      opts = {color: true, update_check: true, sort: "default", fold_working: false}
      parser = OptionParser.new(USAGE) do |p|
        p.on("--version", "Print the version") {
          @out.puts VERSION
          exit
        }
        p.on("--mod-dir", "Print the pane's directory, for CLAUDE_CODE_PLUGIN_DIRS") {
          @out.puts Mod.link(force: true)
          exit
        }
        p.on("--fixture PATH", "Read sessions from an agents.json instead of the daemon") { |path| opts[:fixture] = path }
        p.on("--headless", "Keep the pane's snapshot fresh without a screen") { opts[:headless] = true }
        p.on("--reap", "Delete background sessions idle 14 days") { opts[:reap] = true }
        p.on("--no-color", "Draw without color") { opts[:color] = false }
        p.on("--sort=ORDER", Store::SORTS, "Order every section by activity, newest message first") { |order| opts[:sort] = order }
        p.on("--fold-working", "Fold sessions still at work into a Working section") { opts[:fold_working] = true }
        p.on("--notify", "Send a desktop notification when a session needs you or finishes") { opts[:notify] = true }
        p.on("--auto-update", "Install a release found today before launching") { opts[:auto_update] = true }
        p.on("--no-update-check", "Never look for a newer release") { opts[:update_check] = false }
        # --listen-lan wins over --listen, whichever came last.
        p.on("--listen[=PORT]", "Let a phone on this Mac start sessions") { |port| opts[:listen] = {lan: false, port: port} unless opts.dig(:listen, :lan) }
        p.on("--listen-lan[=PORT]", "Let a phone on your network start sessions") { |port| opts[:listen] = {lan: true, port: port} }
        p.on("--listen-allow-modes=MODES", "The permission modes a phone may start in") { |modes| opts[:allow_modes] = modes }
      end
      strictly(parser, argv)
      opts
    end

    def subcommand(name)
      parser = OptionParser.new(USAGE)
      yield parser if block_given?
      strictly(parser, @argv.drop(1))
    rescue OptionParser::ParseError => e
      abort "claude-inbox #{name}: #{e.message}"
    end

    # Exact names only, so a typo is an error rather than the flag it abbreviates.
    def strictly(parser, argv)
      parser.require_exact = true
      rest = parser.parse(argv)
      raise OptionParser::InvalidArgument, rest.first if rest.any?
    end
  end
end
