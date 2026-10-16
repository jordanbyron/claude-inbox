# frozen_string_literal: true

require_relative "subprocess"

module ClaudeInbox
  # Puts text on the system clipboard through the tool this platform has:
  # pbcopy on macOS, wl-copy or xclip elsewhere.
  module Clipboard
    TOOLS = {"pbcopy" => [], "wl-copy" => [], "xclip" => %w[-selection clipboard]}.freeze

    class Failed < StandardError; end

    module_function

    # True once a tool took the text, false when none is on PATH.
    def copy(text, platform: RUBY_PLATFORM, path: ENV.fetch("PATH", ""), run: Subprocess.method(:capture))
      argv = command(platform: platform, path: path)
      return false unless argv
      result = run.call(*argv, input: text)
      raise Failed, "#{File.basename(argv.first)} failed: #{result.err.strip}" unless result.success?
      true
    end

    # The argv that writes the clipboard here, or nil without a tool on PATH.
    def command(platform: RUBY_PLATFORM, path: ENV.fetch("PATH", ""))
      names = platform.include?("darwin") ? %w[pbcopy] : %w[wl-copy xclip]
      dirs = path.split(File::PATH_SEPARATOR)
      names.each do |name|
        dir = dirs.find { |d| File.executable?(File.join(d, name)) }
        return [File.join(dir, name), *TOOLS[name]] if dir
      end
      nil
    end
  end
end
