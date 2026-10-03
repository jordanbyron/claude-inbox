# frozen_string_literal: true

require "fileutils"
require "json"

module ClaudeInbox
  # Where the Claude Code pane ships, and a path to it that holds still: the
  # gem's own folder moves with every version, so a link under ~/.config is
  # what settings.json names, refreshed by the installed gem on every launch.
  module Mod
    DIR = File.expand_path("../../mod", __dir__)
    LINK = File.join(Dir.home, ".config", "claude-inbox", "mod")
    NAME = "inbox-pane"
    CHECKOUT = File.exist?(File.expand_path("../../.git", __dir__))

    # Points the link at this gem's mod folder and returns the link. A folder
    # of that name that is not a link is left alone. From a checkout only a
    # missing or dangling link is made, unless forced (`--mod-dir` asks for
    # it), so a worktree's launch never takes the path from the installed gem.
    def self.link(link: LINK, dir: DIR, force: false, checkout: CHECKOUT)
      FileUtils.mkdir_p(File.dirname(link))
      return link if File.exist?(link) && !File.symlink?(link)
      if File.symlink?(link)
        return link if File.readlink(link) == dir
        return link if checkout && !force && File.directory?(File.readlink(link))
        File.delete(link)
      end
      File.symlink(dir, link)
      link
    end

    Installed = Data.define(:added, :removed)

    # Links the mod and adds the link to CLAUDE_CODE_PLUGIN_DIRS in Claude
    # Code's user settings, keeping any folders already there; forced, it
    # drops the other folders holding this plugin, such as a worktree's.
    # Raises JSON::ParserError rather than rewrite a settings file it cannot
    # read.
    def self.install(settings: File.join(Dir.home, ".claude", "settings.json"), link: LINK, dir: DIR, force: false)
      self.link(link: link, dir: dir, force: true)
      json = File.exist?(settings) ? JSON.parse(File.read(settings)) : {}
      env = json["env"] ||= {}
      dirs = env["CLAUDE_CODE_PLUGIN_DIRS"].to_s.split(File::PATH_SEPARATOR).map(&:strip).reject(&:empty?)
      kept = dirs.reject { |d| force && d != link && plugin?(d) }
      wanted = kept.include?(link) ? kept : [*kept, link]
      installed = Installed.new(added: !kept.include?(link), removed: dirs - kept)
      return installed if wanted == dirs

      env["CLAUDE_CODE_PLUGIN_DIRS"] = wanted.join(File::PATH_SEPARATOR)
      FileUtils.mkdir_p(File.dirname(settings))
      File.write("#{settings}.tmp", JSON.pretty_generate(json) + "\n")
      File.rename("#{settings}.tmp", settings)
      installed
    end

    def self.plugin?(folder)
      JSON.parse(File.read(File.join(folder, ".claude-plugin", "plugin.json")))["name"] == NAME
    rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES, JSON::ParserError
      false
    end
    private_class_method :plugin?
  end
end
