# frozen_string_literal: true

require "json"

module ClaudeInbox
  # What `claude` will use when a flag is left off: read from the same
  # settings files it reads, most specific wins. Values are strings, or
  # nil when nothing sets them — then the CLI decides at launch.
  module Settings
    Defaults = Struct.new(:model, :effort, :permission_mode, :remote)

    def self.defaults(cwd, home: Dir.home)
      user = read(File.join(home, ".claude", "settings.json"))
      project = read(File.join(cwd, ".claude", "settings.json"))
      local = read(File.join(cwd, ".claude", "settings.local.json"))
      layers = [user, project, local]
      Defaults.new(
        model: pick(layers, "model"),
        effort: pick(layers, "effortLevel"),
        permission_mode: pick(layers, "permissions", "defaultMode"),
        remote: remote_control(user, project, local, read(File.join(home, ".claude.json")))
      )
    end

    # "Enable Remote Control for all sessions" in /config. The CLI lets a
    # repo turn it off but only user scope turn it on, and still honours the
    # copy older versions kept in ~/.claude.json.
    def self.remote_control(user, project, local, legacy)
      return "no" if project["remoteControlAtStartup"] == false || local["remoteControlAtStartup"] == false
      [user, legacy].each do |h|
        v = h["remoteControlAtStartup"]
        return v ? "yes" : "no" if [true, false].include?(v)
      end
      nil
    end

    def self.read(path)
      JSON.parse(File.read(path))
    rescue Errno::ENOENT, Errno::EACCES, JSON::ParserError
      {}
    end

    def self.pick(layers, *keys)
      layers.reverse_each do |h|
        v = h.dig(*keys)
        return v.to_s if v.is_a?(String) || v.is_a?(Numeric)
      end
      nil
    end
  end
end
