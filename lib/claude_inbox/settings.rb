# frozen_string_literal: true

require "json"

module ClaudeInbox
  # What a `claude` session in a directory gets from the settings files it
  # reads, most specific wins: the defaults for flags left off, and the
  # plugins it loads.
  module Settings
    # Strings, or nil when nothing sets them: then the CLI decides at launch.
    Defaults = Struct.new(:model, :effort, :permission_mode, :remote)

    def self.defaults(cwd, home: Dir.home)
      user, project, local = layers = layers(cwd, home)
      Defaults.new(
        model: pick(layers, "model"),
        effort: pick(layers, "effortLevel"),
        permission_mode: pick(layers, "permissions", "defaultMode"),
        remote: remote_control(user, project, local, read(File.join(home, ".claude.json")))
      )
    end

    # The "name@marketplace" keys of the plugins a session in cwd loads.
    # Its install scope plays no part; see docs/cli-quirks.md.
    def self.enabled_plugins(cwd, home: Dir.home)
      layers(cwd, home).each_with_object({}) do |h, on|
        plugins = h["enabledPlugins"]
        on.merge!(plugins) if plugins.is_a?(Hash)
      end.select { |_, v| v == true }.keys
    end

    def self.layers(cwd, home)
      [
        read(File.join(home, ".claude", "settings.json")),
        read(File.join(cwd, ".claude", "settings.json")),
        read(File.join(cwd, ".claude", "settings.local.json"))
      ]
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
    private_class_method :layers, :remote_control, :pick
  end
end
