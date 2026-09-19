# frozen_string_literal: true

require_relative "lib/claude_inbox"

Gem::Specification.new do |spec|
  spec.name = "claude-inbox"
  spec.version = ClaudeInbox::VERSION
  spec.authors = ["Jordan Byron"]
  spec.summary = "Inbox-style triage on top of Claude Code's background sessions"
  spec.description = "A companion to `claude agents`, not a replacement: it reads the same daemon state " \
    "through `claude agents --json` and adds snooze, auto-settle and the session's pull request."
  spec.homepage = "https://github.com/jordanbyron/claude-inbox"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files = `git ls-files -z lib exe README.md LICENSE`.split("\x0")
  spec.bindir = "exe"
  spec.executables = ["claude-inbox"]
  spec.require_paths = ["lib"]

  spec.add_dependency "tty-cursor", "~> 0.7"
  spec.add_dependency "tty-reader", "~> 0.9"
  spec.add_dependency "tty-screen", "~> 0.8"
  spec.add_dependency "tty-box", "~> 0.7"
  spec.add_dependency "pastel", "~> 0.8"
  spec.add_dependency "unicode-display_width", "~> 2.6"
end
