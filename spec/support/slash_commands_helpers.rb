# frozen_string_literal: true

require "fileutils"

# Writes skills and commands onto disk the way the CLI lays them out.
module SlashCommandsHelpers
  def skill(root, name, description, extra = "")
    FileUtils.mkdir_p("#{root}/#{name}")
    File.write("#{root}/#{name}/SKILL.md", "---\nname: #{name}\ndescription: #{description}\n#{extra}---\n\nbody\n")
  end

  def command(root, name, body)
    FileUtils.mkdir_p(File.dirname("#{root}/#{name}.md"))
    File.write("#{root}/#{name}.md", body)
  end
end

RSpec.configure { |config| config.include SlashCommandsHelpers, :slash_commands }
