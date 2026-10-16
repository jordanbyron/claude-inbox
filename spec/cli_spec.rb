# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeInbox::CLI do
  let(:dir) { Dir.mktmpdir }
  let(:config) { File.join(dir, "config") }
  let(:env) { {} }
  let(:out) { StringIO.new }
  let(:lock) { ClaudeInbox::WriterLock.disabled }
  let(:agents) { fixture_path("agents.json") }

  after { FileUtils.remove_entry(dir) }

  let(:cli) { ->(*argv) { described_class.new(argv, env: env, config: config, lock: lock, out: out) } }

  describe "#options" do
    it "puts the config file's flags before the typed ones" do
      File.write(config, "--no-color --listen-allow-modes=plan\n")
      expect(cli["--listen-allow-modes=default"].options).to include(color: false, allow_modes: "default")
    end

    it "takes neither the config file nor the environment with --fixture" do
      File.write(config, "--no-color\n")
      env["CLAUDE_INBOX_LISTEN"] = "lan"
      expect(cli["--fixture", agents].options).to include(fixture: agents, color: true, listen: nil)
      expect(cli["--fixture", agents, "--listen"].options[:listen]).to include(lan: false, port: 7433)
    end

    it "widens the listener to the LAN when --listen-lan says so, whatever order the flags came in" do
      File.write(config, "--listen-lan\n")
      expect(cli["--listen=8080"].options[:listen]).to include(lan: true, port: 7433)
      expect(cli["--listen-lan=9000", "--listen=8080"].options[:listen]).to include(lan: true, port: 9000)
      File.delete(config)
      expect(cli["--listen=8080"].options[:listen]).to include(lan: false, port: 8080)
    end

    it "falls back to the environment for the listener" do
      env.merge!("CLAUDE_INBOX_LISTEN" => "lan:7500", "CLAUDE_INBOX_LISTEN_ALLOW_MODES" => "plan")
      expect(cli[].options[:listen]).to eq({port: 7500, lan: true, allowed_modes: %w[plan]})
    end

    it "refuses an unknown flag, an abbreviation, a stray argument and a bad port" do
      [["--bogus"], ["--no-col"], ["inbox"], ["--listen=http"], ["--fixture"]].each do |argv|
        expect { cli[*argv].options }.to raise_error(SystemExit).and output(/\Aclaude-inbox: /).to_stderr
      end
    end

    it "names the config file when a line of it won't parse" do
      File.write(config, "--listen-lan \"\n")
      expect { cli[].options }.to raise_error(SystemExit).and output(/#{Regexp.escape(config)}/).to_stderr
    end
  end

  describe "#app_options" do
    it "reads a fixture's sessions and keeps its listener apart from the real one" do
      opts = cli["--fixture", agents, "--listen=0"].app_options
      expect(opts[:client]).to be_a(ClaudeInbox::FixtureClient)
      expect(opts[:listen]).to include(fixture: true, port: 0, lock_path: File.join(Dir.tmpdir, "claude-inbox-fixture", "listen.lock"))
      expect(opts).not_to include(:reaper, :updater, :argv)
    end

    it "arms the reaper only with --reap and checks for updates unless told not to" do
      expect(cli[].app_options[:reaper].instance_variable_get(:@enabled)).to be(false)
      expect(cli["--reap"].app_options[:reaper].instance_variable_get(:@enabled)).to be(true)
      expect(cli[].app_options[:updater]).to be_a(ClaudeInbox::Updater)
      expect(cli["--no-update-check"].app_options[:updater]).to be_nil
    end

    it "notifies only with --notify" do
      expect(cli[].app_options[:notifier].instance_variable_get(:@enabled)).to be(false)
      expect(cli["--notify"].app_options[:notifier].instance_variable_get(:@enabled)).to be(true)
      expect(cli["--fixture", agents, "--notify"].app_options[:notifier].instance_variable_get(:@enabled)).to be(true)
    end

    it "hands App the typed arguments for a relaunch, not the config's" do
      File.write(config, "--no-color\n")
      expect(cli["--reap"].app_options).to include(argv: ["--reap"], color: false)
    end

    it "reads along without writing when another inbox holds the writer lock" do
      first, second = Array.new(2) { described_class.new(["--reap"], env: env, config: config, lock: ClaudeInbox::WriterLock.new(path: File.join(dir, "writer.lock")), out: out) }
      expect(first.app_options[:store]).to be_writable
      opts = second.app_options
      expect(opts[:store]).not_to be_writable
      expect(opts[:reaper].instance_variable_get(:@enabled)).to be(false)
      expect(opts[:notifier].instance_variable_get(:@enabled)).to be(false)
    end
  end

  describe "#run" do
    it "prints the version before reading the config file" do
      File.write(config, "\"\n")
      expect { cli["--version"].run }.to raise_error(SystemExit)
      expect(out.string).to eq("#{ClaudeInbox::VERSION}\n")
    end

    it "refuses --headless with --fixture" do
      expect { cli["--headless", "--fixture", agents].run }.to raise_error(SystemExit).and output(/takes no --fixture/).to_stderr
    end

    it "installs the pane, forced with --force" do
      installed = ClaudeInbox::Mod::Installed.new(added: true, removed: ["/old"], command_set: false)
      expect(ClaudeInbox::Mod).to receive(:install).with(force: true).and_return(installed)
      expect(cli["install", "--force"].run).to be(true)
      expect(out.string).to eq("Removed /old from ~/.claude/settings.json.\n" \
        "Added the pane to ~/.claude/settings.json. New Claude Code sessions load it; /inbox opens it.\n")
    end

    it "takes no launch flag after a subcommand" do
      expect { cli["install", "--reap"].run }.to raise_error(SystemExit).and output(/\Aclaude-inbox install: invalid option: --reap/).to_stderr
      expect { cli["update", "now"].run }.to raise_error(SystemExit).and output(/\Aclaude-inbox update: invalid argument: now/).to_stderr
    end

    it "says when there is nothing to update" do
      updater = instance_double(ClaudeInbox::Updater, check: nil, kind: :gem)
      allow(ClaudeInbox::Updater).to receive(:new).and_return(updater)
      expect(cli["update"].run).to be(true)
      expect(out.string).to eq("claude-inbox #{ClaudeInbox::VERSION} is the latest release.\n")
    end
  end
end
