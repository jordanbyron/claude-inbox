# frozen_string_literal: true

require "fileutils"

module ClaudeInbox
  # Where the Claude Code pane ships, and a path to it that holds still: the
  # gem's own folder moves with every version, so a link under ~/.config is
  # what settings.json names, refreshed by the installed gem on every launch.
  module Mod
    DIR = File.expand_path("../../mod", __dir__)
    LINK = File.join(Dir.home, ".config", "claude-inbox", "mod")
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
  end
end
