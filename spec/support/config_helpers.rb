# frozen_string_literal: true

require "tmpdir"

# Runs ClaudeInbox::Config.argv against a throwaway config file.
module ConfigHelpers
  def argv_with(contents, typed = [])
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config")
      File.write(path, contents) if contents
      ClaudeInbox::Config.argv(typed, path: path)
    end
  end
end

RSpec.configure { |config| config.include ConfigHelpers, :config }
