#!/bin/bash
# Readies a Claude Code cloud session for bin/ci: the gems, Ruby's gem
# executables on PATH, and gh-signoff.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "$CLAUDE_PROJECT_DIR"

# The image's ruby puts gem executables (rspec, standardrb) in a bindir that
# isn't on PATH, so `bundle exec rspec` can't find them.
bindir=$(ruby -e 'print Gem.bindir')
echo "export PATH=\"$bindir:\$PATH\"" >> "${CLAUDE_ENV_FILE:-/dev/null}"
export PATH="$bindir:$PATH"

bundle install --quiet

# `gh extension install` asks the GitHub API for releases, which the session's
# proxy refuses for repositories not attached to it; a clone goes through.
ext="${XDG_DATA_HOME:-$HOME/.local/share}/gh/extensions/gh-signoff"
if [ ! -d "$ext" ]; then
  git clone --quiet --depth 1 https://github.com/basecamp/gh-signoff "$ext" ||
    echo "session-start: couldn't install gh-signoff; bin/ci will run but can't sign off" >&2
fi
