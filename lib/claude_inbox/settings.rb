# frozen_string_literal: true

require "json"

module ClaudeInbox
  # What `claude` will use when a flag is left off: read from the same
  # settings files it reads, most specific wins. Values are strings, or
  # nil when nothing sets them — then the CLI decides at launch.
  module Settings
    Defaults = Struct.new(:model, :effort, :permission_mode)

    def self.defaults(cwd, home: Dir.home)
      layers = [
        File.join(home, ".claude", "settings.json"),
        File.join(cwd, ".claude", "settings.json"),
        File.join(cwd, ".claude", "settings.local.json")
      ].map { |path| read(path) }
      Defaults.new(
        model: pick(layers, "model"),
        effort: pick(layers, "effortLevel"),
        permission_mode: pick(layers, "permissions", "defaultMode")
      )
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
