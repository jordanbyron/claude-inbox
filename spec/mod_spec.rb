# frozen_string_literal: true

require "tmpdir"

RSpec.describe ClaudeInbox::Mod do
  it "links a stable path to the gem's mod folder and follows the folder when it moves" do
    Dir.mktmpdir do |dir|
      link = File.join(dir, "config", "mod")
      first = File.join(dir, "gem-1.0", "mod")
      second = File.join(dir, "gem-1.1", "mod")
      expect(described_class.link(link: link, dir: first, checkout: false)).to eq(link)
      expect(File.readlink(link)).to eq(first)
      described_class.link(link: link, dir: second, checkout: false)
      expect(File.readlink(link)).to eq(second)
    end
  end

  it "from a checkout only mends a missing or dangling link, unless forced" do
    Dir.mktmpdir do |dir|
      link = File.join(dir, "mod")
      installed = File.join(dir, "installed", "mod")
      worktree = File.join(dir, "worktree", "mod")
      FileUtils.mkdir_p(installed)
      described_class.link(link: link, dir: worktree, checkout: true)
      expect(File.readlink(link)).to eq(worktree)
      File.delete(link)
      File.symlink(installed, link)
      described_class.link(link: link, dir: worktree, checkout: true)
      expect(File.readlink(link)).to eq(installed)
      described_class.link(link: link, dir: worktree, checkout: true, force: true)
      expect(File.readlink(link)).to eq(worktree)
      FileUtils.rm_rf(File.join(dir, "worktree"))
      described_class.link(link: link, dir: installed, checkout: true)
      expect(File.readlink(link)).to eq(installed)
    end
  end

  it "leaves a real folder of that name alone" do
    Dir.mktmpdir do |dir|
      link = File.join(dir, "mod")
      Dir.mkdir(link)
      described_class.link(link: link, dir: File.join(dir, "elsewhere"), checkout: false)
      expect(File.symlink?(link)).to be(false)
    end
  end

  it "ships beside lib" do
    expect(File.exist?(File.join(described_class::DIR, ".claude-plugin", "plugin.json"))).to be(true)
  end

  it "writes the snapshot the pane's fixture says it reads" do
    fixture = File.read(File.join(described_class::DIR, "tests", "snapshot.fixture.ts"))[/`([\s\S]*)`/, 1]
    now = Time.at(1_789_600_000)
    pr = ClaudeInbox::PullRequest.new(number: 7, url: "https://github.com/o/r/pull/7", state: "OPEN", title: "t")
    sessions = [
      session(id: "a1", state: "blocked", name: "needs an answer", session_id: "u-a1"),
      session(id: "b2", state: "working", name: "still going", prs: [pr], session_id: "u-b2"),
      session(id: "c3", state: "done", name: "put away", session_id: "u-c3")
    ]
    entries = {"c3" => {"last_state" => "done", "state_since" => now.to_i - 90, "settled_at" => now.to_i - 60}}
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snapshot.json")
      ClaudeInbox::Snapshot.new(path: path).write(ClaudeInbox::Store.sectionize(sessions, entries, now), now)
      expect(JSON.parse(File.read(path))).to eq(JSON.parse(fixture))
    end
  end
end
