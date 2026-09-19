# What the real CLI does (2.1.273)

Things the inbox relies on that `claude --help` doesn't tell you. Checked
against 2.1.273 unless noted; re-check after a CLI upgrade.

- `claude agents --json --all` matches the documented shape. A `done` session
  can still carry a `pid` and `status: idle`.
- Interactive sessions (a `claude` you started in a terminal yourself) appear
  in the JSON with no `id` and no `state`, only `status`, and cannot be
  attached, peeked or stopped from outside. The JSON calls a terminal you
  opened, a Remote Control worker, a sub-agent and a headless `claude -p` run
  all "interactive", each named after its directory. The process tree tells
  them apart: a remote worker runs with `--sdk-url` under a `claude rc`
  parent, a sub-agent has a `claude` for a parent, and a headless run has
  `-p` or the SDK's stream flags on its command line.
- `~/.claude/jobs/<id>/state.json` is where the daemon keeps what the JSON
  leaves out: `children` (scanned PR and issue links), `intent`,
  `worktreePath`, `worktreeBranch`, token count and the transcript path, plus
  the line the agents view prints under a row: `detail` is the session's
  status line, `needs` what it is waiting on while blocked, `output.result`
  its closing summary once done. `/color` lands there too, as `color`. The
  CLI offers eight colors, and its own tmux code says what they mean to a
  terminal: six are ansi names, `orange` and `pink` are 256-color indexes 208
  and 205. Interactive sessions have no job file, so no color and no line.
- `~/.claude/gh-pr-status-cache.json` is keyed by PR url and calls an open
  draft `DRAFT`; `gh pr view` reports `OPEN` plus `isDraft`. The cache only
  covers PRs Claude Code's own sessions opened, so a link scan finds plenty
  it doesn't know about.
- `claude logs <id>` is not plain text. It is a replay of the session's
  terminal output: cursor positioning, erase-line, color. Words are often
  separated by cursor motion rather than spaces, so stripping escapes yields
  run-together garbage. Feeding it through a screen grid (`VtScreen`)
  produces readable text.
- `claude logs` fails with "job not found" for a finished session whose
  process the supervisor has reaped. The peek pane shows a notice instead.
- `claude attach --help` says `←` returns to agent view and `Ctrl+Z` drops
  to the shell. Under the hood `←` makes the attach process exec `claude
  agents` in place, same pid, using its own executable path, so a PATH shim
  never sees it. No flag suppresses just that relaunch:
  `CLAUDE_CODE_DISABLE_AGENT_VIEW=1` disables `agents`, `attach` and `logs`
  alike. So the inbox watches its child's command line and, the moment it
  turns into the agents view, terminates it. The round trip is about 0.4s
  and the agents view never draws a frame. `Ctrl+Z` is handled locally by
  the attach client and needs no trick.
- `claude rm` refuses a worktree holding unpushed commits and offers a
  `--discard-unpushed` token to override it. Nothing here passes that token.
- A prompt beginning with a slash command is expanded, `$ARGUMENTS` and all,
  in `-p` and `--bg` alike (checked on 2.1.274 with a project command).
  Installed plugins are listed in `~/.claude/plugins/installed_plugins.json`,
  keyed `name@marketplace`, each pointing at its `installPath`; claude.ai's
  synced skills sit in `~/.claude/skills/synced/<bucket>/<name>/SKILL.md`
  and show up as `anthropic-skills:<name>`. Built-ins such as `/init` live
  inside the CLI and aren't on disk.
- With bracketed paste on, an image paste arrives as an empty fence
  (`\e[200~\e[201~`), since an image has no text form. That empty fence is
  the signal to read the clipboard, which is how Claude Code does it too. A
  dropped file arrives the same way, as its shell-escaped path. Reading the
  clipboard goes through `osascript`, so it is macOS only.
- Terminal.app puts the tty's active process in the tab title, so a poller
  that forks `claude` every few seconds makes the title flicker. Every helper
  subprocess here is started with `setsid` so it has no controlling tty.
