# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "json"

RSpec.describe ClaudeInbox::SlashCommands do
  describe ".list" do
    subject(:list) { described_class.list(cwd: proj, home: home) }

    let(:home) { Dir.mktmpdir }
    let(:proj) { home }
    let(:files) { {} }

    before do
      files.each do |path, body|
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, body)
      end
    end

    after { FileUtils.rm_rf([home, proj]) }

    context "with skills and commands in the project and the user's home" do
      let(:proj) { Dir.mktmpdir }

      let(:files) do
        {
          "#{home}/.claude/skills/unslop/SKILL.md" => "---\nname: unslop\ndescription: Cut AI tells.\n---\n\nbody\n",
          "#{home}/.claude/skills/shared/SKILL.md" => "---\nname: shared\ndescription: from home\n---\n\nbody\n",
          "#{home}/.claude/commands/frontend/component.md" => "Make a component",
          "#{proj}/.claude/skills/shared/SKILL.md" => "---\nname: shared\ndescription: from project\n---\n\nbody\n",
          "#{proj}/.claude/commands/deploy.md" => "---\ndescription: Ship it\n---\nDeploy $ARGUMENTS"
        }
      end

      it "lists both, project first on a clash" do
        expect(list.map(&:name)).to eq(%w[component deploy shared unslop])
        expect(list.map(&:source)).to eq(%w[user project project user])
        expect(list.find { |c| c.name == "shared" }.description).to eq("from project")
        expect(list.find { |c| c.name == "deploy" }.description).to eq("Ship it")
        expect(list.find { |c| c.name == "component" }.description).to eq("")
        expect(list.first.to_s).to eq("/component")
      end
    end

    context "with folded, quoted and multi-line descriptions" do
      subject(:by_name) { list.to_h { |c| [c.name, c.description] } }

      let(:files) do
        {
          "#{home}/.claude/skills/folded/SKILL.md" =>
            "---\nname: folded\ndescription: >-\n  Send a push notification\n  when something happens.\n---\n\nbody\n",
          "#{home}/.claude/skills/quoted/SKILL.md" => "---\nname: quoted\ndescription: 'It''s quoted: with a colon'\n---\n\nbody\n",
          "#{home}/.claude/skills/dq/SKILL.md" => "---\nname: dq\ndescription: \"Double quoted\"\n---\n\nbody\n",
          "#{home}/.claude/skills/hidden/SKILL.md" =>
            "---\nname: hidden\ndescription: Not for the menu\nuser-invocable: false\n---\n\nbody\n"
        }
      end

      it "reads each up to its first line" do
        expect(by_name["folded"]).to eq("Send a push notification")
        expect(by_name["quoted"]).to eq("It's quoted: with a colon")
        expect(by_name["dq"]).to eq("Double quoted")
        expect(by_name).not_to include("hidden")
      end
    end

    context "with plugin and synced skills" do
      let(:plugin) { ".claude/plugins/cache/official/skill-creator/abc" }
      let(:files) do
        {
          "#{home}/#{plugin}/skills/skill-creator/SKILL.md" =>
            "---\nname: skill-creator\ndescription: Make skills\n---\n\nbody\n",
          "#{home}/#{plugin}/commands/eval.md" => "---\ndescription: Run evals\n---",
          "#{home}/.claude/plugins/installed_plugins.json" => {
            version: 2,
            plugins: {"skill-creator@official" => [{scope: "user", installPath: "#{home}/#{plugin}"}]}
          }.to_json,
          "#{home}/.claude/skills/synced/bucket-1/docs/SKILL.md" => "---\nname: docs\ndescription: Living docs\n---\n\nbody\n"
        }
      end

      it "namespaces them the way the CLI does" do
        expect(list.map(&:name)).to eq(%w[anthropic-skills:docs skill-creator:eval skill-creator:skill-creator])
        expect(list.map(&:source)).to eq(%w[synced plugin plugin])
      end
    end

    context "with nothing installed at all" do
      it "copes" do
        expect(list).to eq([])
      end
    end
  end

  describe ".match" do
    let(:cmds) { %w[review code-review unslop Babysit].map { |n| described_class::Command.new(n, "", "user") } }

    it "matches by prefix first, then anywhere in the name, ignoring case" do
      expect(described_class.match(cmds, "re").map(&:name)).to eq(%w[review code-review])
      expect(described_class.match(cmds, "b").map(&:name)).to eq(%w[Babysit])
      expect(described_class.match(cmds, "").map(&:name)).to eq(%w[review code-review unslop Babysit])
      expect(described_class.match(cmds, "zz")).to eq([])
    end
  end
end
