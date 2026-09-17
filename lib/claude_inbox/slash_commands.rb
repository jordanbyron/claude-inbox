# frozen_string_literal: true

require "json"

module ClaudeInbox
  # The slash commands `claude` would offer at its own prompt, read from the
  # same places it reads them: `.claude/commands/*.md` and
  # `.claude/skills/*/SKILL.md` under the project and the home directory,
  # the skills and commands of installed plugins (named `plugin:name`), and
  # the skills claude.ai syncs down (`anthropic-skills:name`). Built-ins
  # live inside the CLI and are not listed; typing one still works, since
  # the prompt goes to `claude --bg` verbatim.
  #
  # Pure: filesystem in, plain values out. Nothing here runs `claude`.
  module SlashCommands
    Command = Struct.new(:name, :description, :source) do
      def to_s = "/#{name}"
    end

    SYNCED_PLUGIN = "anthropic-skills"

    module_function

    # The project wins over the home directory when both define the same
    # name, as it does in the CLI.
    def list(cwd:, home: Dir.home)
      found = {}
      add = ->(cmd) { found[cmd.name] ||= cmd }
      local(File.join(cwd, ".claude"), "project").each(&add)
      local(File.join(home, ".claude"), "user").each(&add)
      plugins(home).each(&add)
      synced(home).each(&add)
      found.values.sort_by(&:name)
    end

    def match(commands, query)
      q = query.downcase
      starts, rest = commands.partition { |c| c.name.downcase.start_with?(q) }
      starts + rest.select { |c| c.name.downcase.include?(q) }
    end

    def local(dir, source)
      skills(File.join(dir, "skills"), source) + commands(File.join(dir, "commands"), source)
    end

    def skills(dir, source, prefix: nil)
      Dir.glob(File.join(dir, "*", "SKILL.md")).sort.filter_map do |path|
        meta = frontmatter(path)
        next if meta["user-invocable"] == "false"
        name = File.basename(File.dirname(path))
        Command.new(qualify(prefix, name), meta["description"].to_s, source)
      end
    end

    # A command file's name is its own; a subdirectory only groups them.
    def commands(dir, source, prefix: nil)
      Dir.glob(File.join(dir, "**", "*.md")).sort.map do |path|
        name = File.basename(path, ".md")
        Command.new(qualify(prefix, name), frontmatter(path)["description"].to_s, source)
      end
    end

    # "name", or "plugin:name" when it comes from a plugin.
    def qualify(prefix, name) = [prefix, name].compact.join(":")

    # `installed_plugins.json` maps "name@marketplace" to where the plugin
    # was unpacked: one entry, or a list of them, one per install scope.
    def plugins(home)
      installed = read_json(File.join(home, ".claude", "plugins", "installed_plugins.json"))
      (installed["plugins"] || {}).flat_map do |key, entries|
        plugin = key.split("@").first
        Array(entries).filter_map { |e| e["installPath"] if e.is_a?(Hash) }.uniq.flat_map do |root|
          skills(File.join(root, "skills"), "plugin", prefix: plugin) +
            commands(File.join(root, "commands"), "plugin", prefix: plugin)
        end
      end
    end

    # claude.ai's synced skills sit in one bucket per account under
    # ~/.claude/skills/synced and answer to the anthropic-skills prefix.
    def synced(home)
      Dir.glob(File.join(home, ".claude", "skills", "synced", "*", "")).flat_map do |bucket|
        skills(bucket, "synced", prefix: SYNCED_PLUGIN)
      end
    end

    # The YAML front matter's scalar keys, without a YAML parser: enough
    # for `name`, `description` and `user-invocable`. A folded or quoted
    # description is read up to its first line.
    def frontmatter(path)
      lines = File.foreach(path).first(60)
      return {} unless lines.first&.strip == "---"
      out = {}
      key = nil
      lines[1..].map(&:chomp).each do |line|
        break if line.strip == "---"
        if (m = line.match(/\A([\w-]+):\s*(.*)\z/))
          key = m[1]
          out[key] = unquote(m[2].strip)
        elsif key && out[key].empty? && line.start_with?(" ")
          out[key] = unquote(line.strip)
        end
      end
      out
    rescue Errno::ENOENT, Errno::EACCES
      {}
    end

    def unquote(s)
      s = s.sub(/\A[>|][-+]?\z/, "")
      quoted = s.size >= 2 && ((s.start_with?('"') && s.end_with?('"')) || (s.start_with?("'") && s.end_with?("'")))
      s = s[1..-2] if quoted
      s.gsub("''", "'")
    end

    def read_json(path)
      JSON.parse(File.read(path))
    rescue Errno::ENOENT, Errno::EACCES, JSON::ParserError
      {}
    end
  end
end
