# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "json"

RSpec.describe ClaudeInbox::SlashCommands do
  it "lists project and user skills and commands, project first on a clash" do
    Dir.mktmpdir do |home|
      Dir.mktmpdir do |proj|
        {
          "#{home}/.claude/skills/unslop/SKILL.md" => "---\ndescription: Cut AI tells.\n---\n",
          "#{home}/.claude/skills/shared/SKILL.md" => "---\ndescription: from home\n---\n",
          "#{proj}/.claude/skills/shared/SKILL.md" => "---\ndescription: from project\n---\n",
          "#{proj}/.claude/commands/deploy.md" => "---\ndescription: Ship it\n---\nDeploy $ARGUMENTS",
          "#{home}/.claude/commands/frontend/component.md" => "Make a component"
        }.each { |path, body| FileUtils.mkdir_p(File.dirname(path)) && File.write(path, body) }
        list = described_class.list(cwd: proj, home: home)
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
      {
        "folded" => "description: >-\n  Send a push notification\n  when something happens.\n",
        "quoted" => "description: 'It''s quoted: with a colon'\n",
        "dq" => "description: \"Double quoted\"\n",
        "hidden" => "description: Not for the menu\nuser-invocable: false\n"
      }.each do |name, frontmatter|
        FileUtils.mkdir_p("#{home}/.claude/skills/#{name}")
        File.write("#{home}/.claude/skills/#{name}/SKILL.md", "---\n#{frontmatter}---\n")
      end
      by = described_class.list(cwd: home, home: home).to_h { |c| [c.name, c.description] }
      expect(by["folded"]).to eq("Send a push notification")
      expect(by["quoted"]).to eq("It's quoted: with a colon")
      expect(by["dq"]).to eq("Double quoted")
      expect(by).not_to include("hidden")
    end
  end

  it "namespaces plugin and synced skills the way the CLI does" do
    Dir.mktmpdir do |home|
      plugin = "#{home}/.claude/plugins/cache/official/skill-creator/abc"
      {
        "#{plugin}/skills/skill-creator/SKILL.md" => "---\ndescription: Make skills\n---\n",
        "#{plugin}/commands/eval.md" => "---\ndescription: Run evals\n---",
        "#{home}/.claude/skills/synced/bucket-1/docs/SKILL.md" => "---\ndescription: Living docs\n---\n",
        "#{home}/.claude/plugins/installed_plugins.json" => {
          version: 2,
          plugins: {"skill-creator@official" => [{scope: "user", installPath: plugin}]}
        }.to_json
      }.each { |path, body| FileUtils.mkdir_p(File.dirname(path)) && File.write(path, body) }
      list = described_class.list(cwd: home, home: home)
      expect(list.map(&:name)).to eq(%w[anthropic-skills:docs skill-creator:eval skill-creator:skill-creator])
      expect(list.map(&:source)).to eq(%w[synced plugin plugin])
    end
  end

  it "copes with nothing installed at all" do
    Dir.mktmpdir do |home|
      expect(described_class.list(cwd: home, home: home)).to eq([])
    end
  end

  it "matches by prefix first, then anywhere in the name, ignoring case" do
    cmds = %w[review code-review unslop Babysit].map { |n| described_class::Command.new(n, "", "user") }
    expect(described_class.match(cmds, "re").map(&:name)).to eq(%w[review code-review])
    expect(described_class.match(cmds, "b").map(&:name)).to eq(%w[Babysit])
    expect(described_class.match(cmds, "").map(&:name)).to eq(%w[review code-review unslop Babysit])
    expect(described_class.match(cmds, "zz")).to eq([])
  end
end
