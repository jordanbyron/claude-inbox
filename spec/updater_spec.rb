# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeInbox::Updater do
  let(:now) { Time.at(1_789_600_000) }
  let(:clock) { StillClock.new(now) }
  let(:dir) { Dir.mktmpdir }
  let(:cache) { File.join(dir, "update.json") }
  let(:fetched) { [] }
  let(:body) { '{"version":"0.6.0"}' }
  let(:fetch) { ->(url) { fetched << url and body } }
  let(:execs) { [] }
  let(:exec) { ->(*argv) { execs << argv } }
  let(:ran) { [] }
  # Keyed by the command without its `git -C <root>` prefix: a string is its
  # output on success, a hash its stderr on failure. Anything else fails.
  let(:answers) { {} }
  let(:run) do
    lambda do |*argv|
      key = (argv.first(2) == ["git", "-C"]) ? argv.drop(3).join(" ") : argv.join(" ")
      ran << key
      answer = answers.fetch(key) { {err: "unknown command: #{key}"} }
      out, err, success = answer.is_a?(Hash) ? ["", answer[:err], false] : [answer, "", true]
      ClaudeInbox::Subprocess::Result.new(out, err, instance_double(Process::Status, success?: success))
    end
  end
  let(:gem_updater) { described_class.new(checkout: false, version: "0.5.0", cache_path: cache, run: run, fetch: fetch, exec: exec, clock: clock) }
  let(:checkout_updater) { described_class.new(checkout: true, root: "/repo", cache_path: cache, run: run, fetch: fetch, exec: exec, clock: clock) }
  let(:upstream) { "abcdef1234567890abcdef1234567890abcdef12" }
  let(:behind) do
    {"config branch.main.remote" => "origin", "fetch --quiet origin" => "", "rev-parse main@{upstream}" => upstream,
     "rev-list --count main..#{upstream}" => "3", "rev-parse --short main" => "1234567"}
  end
  let(:gem_install) { "#{Gem.ruby} #{File.join(RbConfig::CONFIG["bindir"], "gem")} install claude-inbox" }

  after { FileUtils.remove_entry(dir) }

  it "finds a newer gem on rubygems.org and remembers it" do
    update = gem_updater.check
    expect(update).to eq(described_class::Update.new(kind: :gem, current: "0.5.0", latest: "0.6.0", behind: nil))
    expect(update.notice).to eq("v0.6.0 available")
    expect(update.installing).to eq("Installing claude-inbox 0.6.0 over 0.5.0...")
    expect(fetched).to eq([described_class::LATEST_URL])
    expect(JSON.parse(File.read(cache))).to eq("checked_at" => now.to_i, "kind" => "gem", "latest" => "0.6.0")
  end

  it "is nil when the gem is the latest release, or newer than it" do
    expect(gem_updater.check).not_to be_nil
    ["0.6.0", "0.7.0"].each do |version|
      File.delete(cache)
      expect(described_class.new(checkout: false, version: version, cache_path: cache, fetch: fetch, clock: clock).check).to be_nil
    end
  end

  it "raises when rubygems.org cannot be reached or makes no sense, and caches nothing" do
    down = ->(_) { raise described_class::Error, "down" }
    expect { described_class.new(checkout: false, cache_path: cache, fetch: down, clock: clock).check }.to raise_error(described_class::Error, "down")
    junk = described_class.new(checkout: false, cache_path: cache, fetch: ->(_) { "<html>" }, clock: clock)
    expect { junk.check }.to raise_error(described_class::Error, /version/)
    expect(File.exist?(cache)).to be(false)
  end

  it "turns a refused connection into its own error" do
    expect { described_class.fetch_url("https://127.0.0.1:1/latest.json") }.to raise_error(described_class::Error, /unreachable/)
  end

  it "skips the network while the cache is under a day old, unless forced" do
    File.write(cache, JSON.generate(checked_at: now.to_i - described_class::FRESH_FOR + 1, kind: "gem", latest: "0.6.0"))
    expect(gem_updater.check.latest).to eq("0.6.0")
    expect(fetched).to be_empty
    expect(gem_updater.check(force: true).latest).to eq("0.6.0")
    expect(fetched).to eq([described_class::LATEST_URL])
  end

  it "compares a cached version against the one now running" do
    File.write(cache, JSON.generate(checked_at: now.to_i, kind: "gem", latest: "0.6.0"))
    installed = described_class.new(checkout: false, version: "0.6.0", cache_path: cache, fetch: fetch, clock: clock)
    expect(installed.check).to be_nil
    expect(fetched).to be_empty
  end

  it "answers from a fresh cache alone, and otherwise not at all" do
    expect(gem_updater.cached).to be_nil
    File.write(cache, JSON.generate(checked_at: now.to_i, kind: "gem", latest: "0.6.0"))
    expect(gem_updater.cached.notice).to eq("v0.6.0 available")
    File.write(cache, JSON.generate(checked_at: now.to_i - described_class::FRESH_FOR, kind: "gem", latest: "0.6.0"))
    expect(gem_updater.cached).to be_nil
    expect(fetched).to be_empty
  end

  it "asks again once the cache is a day old, unreadable or another install's" do
    [JSON.generate(checked_at: now.to_i - described_class::FRESH_FOR, kind: "gem", latest: "0.6.0"), "{ nope",
      JSON.generate(checked_at: now.to_i, kind: "checkout", latest: "0.6.0")].each do |stale|
      File.write(cache, stale)
      expect(gem_updater.check).not_to be_nil
    end
    expect(fetched.size).to eq(3)
  end

  it "installs the gem with this Ruby's gem command, and forgets what the cache held" do
    answers[gem_install] = "Successfully installed claude-inbox-0.6.0\n"
    File.write(cache, JSON.generate(checked_at: now.to_i, kind: "gem", latest: "0.6.0"))
    expect(gem_updater.apply).to eq(described_class::Applied.new(success: true, output: "Successfully installed claude-inbox-0.6.0\n"))
    expect(File.exist?(cache)).to be(false)
    expect(gem_updater.apply).to be_success
  end

  it "hands back gem install's error when it fails, and keeps the cache" do
    answers[gem_install] = {err: "ERROR:  Could not find a valid gem"}
    File.write(cache, "{}")
    applied = gem_updater.apply
    expect(applied).not_to be_success
    expect(applied.output).to eq("ERROR:  Could not find a valid gem")
    expect(File.exist?(cache)).to be(true)
  end

  it "fetches the remote main tracks and counts how far behind main is" do
    answers.merge!(behind)
    update = checkout_updater.check
    expect(update).to eq(described_class::Update.new(kind: :checkout, current: "1234567", latest: "abcdef1", behind: 3))
    expect(update.notice).to eq("main is 3 behind")
    expect(update.installing).to eq("main is 3 behind, fast-forwarding to abcdef1...")
    expect(ran).to include("fetch --quiet origin")
    expect(fetched).to be_empty
    expect(JSON.parse(File.read(cache))).to eq("checked_at" => now.to_i, "kind" => "checkout", "latest" => upstream)
  end

  it "is nil when main has everything the remote has" do
    answers.merge!(behind, "rev-list --count main..#{upstream}" => "0")
    expect(checkout_updater.check).to be_nil
  end

  it "raises when the fetch fails or main tracks nothing" do
    answers.merge!(behind, "fetch --quiet origin" => {err: "fatal: unable to access"})
    expect { checkout_updater.check }.to raise_error(described_class::Error, /unable to access/)
    answers.delete("config branch.main.remote")
    expect { checkout_updater.check }.to raise_error(described_class::Error, /tracks no remote/)
  end

  it "counts against the cached upstream without fetching while the cache is fresh" do
    answers.merge!(behind)
    File.write(cache, JSON.generate(checked_at: now.to_i, kind: "checkout", latest: upstream))
    expect(checkout_updater.check.behind).to eq(3)
    expect(ran).not_to include("fetch --quiet origin")
  end

  it "fast-forwards main when on it with a clean tree" do
    answers.merge!("symbolic-ref --short HEAD" => "main", "status --porcelain" => "", "merge --ff-only --quiet main@{upstream}" => "")
    expect(checkout_updater.apply).to be_success
    expect(ran.last).to eq("merge --ff-only --quiet main@{upstream}")
  end

  it "refuses to touch another branch or a dirty tree" do
    answers.merge!("symbolic-ref --short HEAD" => "feat/x", "status --porcelain" => "")
    expect(checkout_updater.apply).to eq(described_class::Applied.new(success: false, output: "not on main (on feat/x)"))
    answers.merge!("symbolic-ref --short HEAD" => "main", "status --porcelain" => " M lib/a.rb")
    expect(checkout_updater.apply).to eq(described_class::Applied.new(success: false, output: "the working tree is dirty"))
    expect(ran).not_to include(a_string_starting_with("merge"))
  end

  it "hands back git's error when main cannot fast-forward" do
    answers.merge!("symbolic-ref --short HEAD" => "main", "status --porcelain" => "",
      "merge --ff-only --quiet main@{upstream}" => {err: "fatal: Not possible to fast-forward, aborting.\n"})
    applied = checkout_updater.apply
    expect(applied).not_to be_success
    expect(applied.output).to eq("fatal: Not possible to fast-forward, aborting.\n")
  end

  it "relaunches the gem's binstub, or a checkout's bin, with the same arguments" do
    gem_updater.relaunch(["--listen-lan"])
    checkout_updater.relaunch(["--reap"])
    expect(execs).to eq([["claude-inbox", "--listen-lan"], ["/repo/bin/claude-inbox", "--reap"]])
  end

  it "knows which kind of install it is" do
    expect(gem_updater.kind).to eq(:gem)
    expect(checkout_updater.kind).to eq(:checkout)
  end
end
