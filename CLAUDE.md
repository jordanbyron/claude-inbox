# claude-inbox

A Ruby TUI over `claude agents --json`. README.md says what it does and how the
daemon's JSON is shaped; read it before touching `lib/`.

## Submitting a PR

Follow [CONTRIBUTING.md](CONTRIBUTING.md). The part that matters for an agent:
there is no hosted CI. A PR is ready only once `bin/ci` has passed on the
pushed HEAD and set the green `signoff` status; run it from the branch after
the final push, and confirm with `gh signoff status`.

Work in a git worktree (`.claude/worktrees/<name>`, gitignored), never in the
shared checkout: other sessions commit there concurrently.

## Conventions

- Tests are minitest/spec (`describe` / `it` / `_(x).must_equal`) in
  `test/*_spec.rb`, one spec file per class.
- The UI is keyboard-only with vim bindings; a new action needs a key in
  `Keymap::BINDINGS` and a row in the README key table.
- Commit subjects are `type: what changed` (`fix:`, `feat:`, `refactor:`,
  `docs:`); the body says why, in prose.
- Comments explain a decision or a daemon quirk, not what the next line does.
