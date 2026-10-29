# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "../claude_inbox"

module ClaudeInbox
  # Where the Claude Code pane ships, and a path to it that holds still: the
  # gem's own folder moves with every version, so a link under ~/.config is
  # what settings.json names, refreshed by the installed gem on every launch.
  module Mod
    DIR = File.expand_path("../../mod", __dir__)
    LINK = File.join(Dir.home, ".config", "claude-inbox", "mod")
    NAME = "inbox-pane"
    SETTINGS = File.join(Dir.home, ".claude", "settings.json")
    # What the pane runs headless: a checkout's own, or the gem's from PATH.
    COMMAND = CHECKOUT ? File.expand_path("../../bin/claude-inbox", __dir__) : nil

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

    Installed = Data.define(:added, :removed, :command_set)

    # Links the mod and adds the link to CLAUDE_CODE_PLUGIN_DIRS in Claude
    # Code's user settings, keeping any folders already there; forced, it
    # drops the other folders holding this plugin, such as a worktree's, and
    # sets the command the pane runs to this copy's. Raises JSON::ParserError
    # rather than rewrite a settings file it cannot read.
    def self.install(settings: SETTINGS, link: LINK, dir: DIR, force: false, command: COMMAND)
      self.link(link: link, dir: dir, force: true)
      json = read_settings(settings)
      env = json["env"] ||= {}
      dirs = plugin_dirs(env["CLAUDE_CODE_PLUGIN_DIRS"])
      kept = dirs.reject { |d| force && d != link && plugin?(d) }
      wanted = kept.include?(link) ? kept : [*kept, link]
      options = json.dig("pluginConfigs", NAME, "options") || {}
      replace = force && options["command"] != command
      installed = Installed.new(added: !kept.include?(link), removed: dirs - kept, command_set: replace)
      return installed if wanted == dirs && !replace

      if replace
        command ? options["command"] = command : options.delete("command")
        ((json["pluginConfigs"] ||= {})[NAME] ||= {})["options"] = options
      end
      env["CLAUDE_CODE_PLUGIN_DIRS"] = wanted.join(File::PATH_SEPARATOR)
      FileUtils.mkdir_p(File.dirname(settings))
      File.write("#{settings}.tmp", JSON.pretty_generate(json) + "\n")
      File.rename("#{settings}.tmp", settings)
      installed
    end

    # Whether any folder in CLAUDE_CODE_PLUGIN_DIRS holds the pane, a
    # worktree's included. A settings file it cannot read counts as yes, since
    # install would refuse to touch it.
    def self.installed?(settings: SETTINGS)
      plugin_dirs(read_settings(settings).dig("env", "CLAUDE_CODE_PLUGIN_DIRS")).any? { |d| plugin?(d) }
    rescue JSON::ParserError, Errno::EACCES
      true
    end

    # Asks once, on the first launch that finds the pane missing, whether to
    # add it. Whatever the answer, a marker file keeps it from asking again.
    class Offer
      MARKER = File.join(Dir.home, ".config", "claude-inbox", "pane-offered")

      def self.disabled = new(marker: nil)

      def initialize(marker: MARKER, settings: SETTINGS, link: LINK)
        @marker = marker
        @settings = settings
        @link = link
      end

      # True once: the first time it is asked while the pane is missing.
      def take
        return false if @marker.nil? || File.exist?(@marker) || Mod.installed?(settings: @settings)
        FileUtils.mkdir_p(File.dirname(@marker))
        FileUtils.touch(@marker)
        true
      end

      def install = Mod.install(settings: @settings, link: @link)
    end

    def self.plugin?(folder)
      JSON.parse(File.read(File.join(folder, ".claude-plugin", "plugin.json")))["name"] == NAME
    rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES, JSON::ParserError
      false
    end

    def self.read_settings(path) = File.exist?(path) ? JSON.parse(File.read(path)) : {}

    def self.plugin_dirs(value) = value.to_s.split(File::PATH_SEPARATOR).map(&:strip).reject(&:empty?)
    private_class_method :plugin?, :read_settings, :plugin_dirs
  end
end
