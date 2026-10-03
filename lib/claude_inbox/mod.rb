# frozen_string_literal: true

require "fileutils"

module ClaudeInbox
  # Where the Claude Code pane ships, and a path to it that holds still: the
  # gem's own folder moves with every version, so a link under ~/.config is
  # what settings.json names, refreshed on every launch.
  module Mod
    DIR = File.expand_path("../../mod", __dir__)
    LINK = File.join(Dir.home, ".config", "claude-inbox", "mod")

    # Points the link at this gem's mod folder and returns the link. A
    # folder of that name that is not a link is left alone.
    def self.link(link: LINK, dir: DIR)
      FileUtils.mkdir_p(File.dirname(link))
      return link if File.exist?(link) && !File.symlink?(link)
      File.delete(link) if File.symlink?(link) && File.readlink(link) != dir
      File.symlink(dir, link) unless File.symlink?(link)
      link
    end
  end
end
