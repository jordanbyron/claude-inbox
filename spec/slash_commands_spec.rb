# frozen_string_literal: true

require "claude_inbox/slash_commands"
require "tmpdir"
require "fileutils"
require "json"

RSpec.describe ClaudeInbox::SlashCommands do
  def skill(root, name, description, extra = "")
    FileUtils.mkdir_p("#{root}/#{name}")
    File.write("#{root}/#{name}/SKILL.md", "---\nname: #{name}\ndescription: #{description}\n#{extra}---\n\nbody\n")
  end

  def command(root, name, body)
    FileUtils.mkdir_p(File.dirname("#{root}/#{name}.md"))
    File.write("#{root}/#{name}.md", body)
  end

  it "lists project and user skills and commands, project first on a clash" do
    Dir.mktmpdir do |home|
      Dir.mktmpdir do |proj|
        skill("#{home}/.claude/skills", "unslop", "Cut AI tells.")
        skill("#{home}/.claude/skills", "shared", "from home")
        skill("#{proj}/.claude/skills", "shared", "from project")
        command("#{proj}/.claude/commands", "deploy", "---\ndescription: Ship it\n---\nDeploy $ARGUMENTS")
        command("#{home}/.claude/commands", "frontend/component", "Make a component")
        list = ClaudeInbox::SlashCommands.list(cwd: proj, home: home)
        expect(list.map(&:name)).to eq(%w[component deploy shared unslop])
        expect(list.map(&:source)).to eq(%w[user project project user])
        expect(list.find { |c| c.name == "shared" }.description).to eq("from project")
        expect(list.find { |c| c.name == "deploy" }.description).to eq("Ship it")
        expect(list.find { |c| c.name == "component" }.description).to eq("")
        expect(list.first.to_s).to eq("/component")
      end
    end
  end

  it "reads folded, quoted and multi-line descriptions up to their first line" do
    Dir.mktmpdir do |home|
      root = "#{home}/.claude/skills"
      skill(root, "folded", ">-\n  Send a push notification\n  when something happens.")
      skill(root, "quoted", "'It''s quoted: with a colon'")
      skill(root, "dq", '"Double quoted"')
      skill(root, "hidden", "Not for the menu", "user-invocable: false\n")
      by = ClaudeInbox::SlashCommands.list(cwd: home, home: home).to_h { |c| [c.name, c.description] }
      expect(by["folded"]).to eq("Send a push notification")
      expect(by["quoted"]).to eq("It's quoted: with a colon")
      expect(by["dq"]).to eq("Double quoted")
      expect(by).not_to include("hidden")
    end
  end

  it "namespaces plugin and synced skills the way the CLI does" do
    Dir.mktmpdir do |home|
      plugin = "#{home}/.claude/plugins/cache/official/skill-creator/abc"
      skill("#{plugin}/skills", "skill-creator", "Make skills")
      command("#{plugin}/commands", "eval", "---\ndescription: Run evals\n---")
      FileUtils.mkdir_p("#{home}/.claude/plugins")
      File.write("#{home}/.claude/plugins/installed_plugins.json", {
        version: 2,
        plugins: {"skill-creator@official" => [{scope: "user", installPath: plugin}]}
      }.to_json)
      skill("#{home}/.claude/skills/synced/bucket-1", "docs", "Living docs")
      list = ClaudeInbox::SlashCommands.list(cwd: home, home: home)
      expect(list.map(&:name)).to eq(%w[anthropic-skills:docs skill-creator:eval skill-creator:skill-creator])
      expect(list.map(&:source)).to eq(%w[synced plugin plugin])
    end
  end

  it "copes with nothing installed at all" do
    Dir.mktmpdir do |home|
      expect(ClaudeInbox::SlashCommands.list(cwd: home, home: home)).to eq([])
    end
  end

  it "matches by prefix first, then anywhere in the name, ignoring case" do
    cmds = %w[review code-review unslop Babysit].map { |n| ClaudeInbox::SlashCommands::Command.new(n, "", "user") }
    expect(ClaudeInbox::SlashCommands.match(cmds, "re").map(&:name)).to eq(%w[review code-review])
    expect(ClaudeInbox::SlashCommands.match(cmds, "b").map(&:name)).to eq(%w[Babysit])
    expect(ClaudeInbox::SlashCommands.match(cmds, "").map(&:name)).to eq(%w[review code-review unslop Babysit])
    expect(ClaudeInbox::SlashCommands.match(cmds, "zz")).to eq([])
  end
end
