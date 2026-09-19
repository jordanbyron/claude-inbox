# claude-inbox

A Ruby TUI over `claude agents --json`. README.md says what it does and
[docs/cli-quirks.md](docs/cli-quirks.md) what the daemon and CLI actually do;
read both before touching `lib/`.

## Submitting a PR

Follow [CONTRIBUTING.md](CONTRIBUTING.md). The part that matters for an agent:
there is no hosted CI. A PR is ready only once `bin/ci` has passed on the
pushed HEAD and set the green `signoff` status; run it from the branch after
the final push, and confirm with `gh signoff status`.

Work in a git worktree (`.claude/worktrees/<name>`, gitignored), never in the
shared checkout: other sessions commit there concurrently.

## Conventions

- Tests are minitest/spec (`describe` / `it` / `_(x).must_equal`) in
  `test/**/*_spec.rb`, one spec file per class.
- The UI is keyboard-only with vim bindings; a new action needs a key in
  `Keymap::BINDINGS` and a row in the README key table.
- Commit subjects are `type: what changed` (`fix:`, `feat:`, `refactor:`,
  `docs:`); the body says why, in prose.
- A comment records a decision, a constraint or a daemon quirk the code
  cannot show, in a line or two. Code that needs a comment to be read is
  code to rewrite until it doesn't. A class comment says what the class is
  for; how it works is the code's job.
