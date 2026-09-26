# frozen_string_literal: true

# Keystrokes for the NewSessionForm specs; `type` presses into the group's `form`.
module NewSessionHelpers
  def type(str) = str.each_char { |c| form.press(c, c) }

  def type_into(f, str) = str.each_char { |c| f.press((c == " ") ? :space : c, c) }

  # A form over a home with three skills and a project with one command.
  def with_commands
    Dir.mktmpdir do |home|
      Dir.mktmpdir do |proj|
        %w[unslop unsplit babysit].each do |n|
          FileUtils.mkdir_p("#{home}/.claude/skills/#{n}")
          File.write("#{home}/.claude/skills/#{n}/SKILL.md", "---\ndescription: #{n} does things\n---\n")
        end
        FileUtils.mkdir_p("#{proj}/.claude/commands")
        File.write("#{proj}/.claude/commands/deploy.md", "---\ndescription: Ship it\n---\n")
        yield ClaudeInbox::NewSessionForm.new(cwd: proj, pastel: Pastel.new(enabled: false), home: home)
      end
    end
  end
end

RSpec.configure { |config| config.include NewSessionHelpers, :new_session }
