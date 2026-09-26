# frozen_string_literal: true

# Reads the Remote Control default afresh from the settings files. Uses the
# group's `home` and `proj`.
module SettingsHelpers
  def remote = ClaudeInbox::Settings.defaults(proj, home: home).remote
end

RSpec.configure { |config| config.include SettingsHelpers, :settings }
