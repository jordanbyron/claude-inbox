# claude-inbox

Inbox-style triage on top of Claude Code's background sessions. A companion to
`claude agents`, not a replacement: it reads the same daemon state through
`claude agents --json` and adds **snooze** and **auto-settle**.

```
bin/claude-inbox                       # live
bin/claude-inbox --fixture test/fixtures/agents.json   # no daemon needed
```

Requires Ruby 3.2+ and a `claude` on PATH with the agents feature.

## Sections

1. **Needs you** — `blocked` or `failed`.
2. **Working** — `working`, plus recently finished sessions that have not settled yet,
   plus interactive sessions (dimmed, not selectable: they have no id).
3. **Snoozed** — sorted by wake time; parked ("until I wake it") entries last.
4. **Settled** — `done`/`stopped` and quiet for 10 minutes. Collapsed; Enter expands.

## Keys

Keyboard only, vim flavoured. Arrows work too.

| Key | Action |
|---|---|
| `j` `k` | move down / up |
| `gg` `G` | first / last row |
| `Ctrl-d` `Ctrl-u` | half page down / up (`Ctrl-f` `Ctrl-b` full page) |
| `Enter` `l` | attach (full-screen handoff; `←`, `Ctrl+Z` or `/exit` return here), or expand Settled |
| `h` | close the peek pane, else collapse Settled |
| `za` `zo` `zc` | toggle / open / close the Settled fold |
| `p` `Tab` | toggle the read-only peek pane |
| `J` `K` (`Ctrl-e` `Ctrl-y`) | scroll the peek pane |
| `s` | snooze: `1` 15m · `2` 1h · `3` tomorrow 9am · `4` until woken |
| `u` | wake a snoozed session now |
| `a` | set a local alias (never touches the real session name) |
| `x` | stop the session (`y` to confirm) |
| `/` | filter by name or cwd; `Enter` keeps it, `Esc` clears |
| `:q` | quit (`:peek`, `:refresh` also exist) |
| `R` | poll now |
| `q` | quit |

Bindings live in `ClaudeInbox::Keymap`, a pure resolver with chord support
that is unit tested on its own.

## Rules

Both rules are pure functions in `ClaudeInbox::Store` and are the only place
triage logic lives.

**Wake.** A snoozed session returns when its timer elapses, when you press `u`,
or when it *becomes* blocked or failed after being snoozed. A session that was
already blocked when you snoozed it stays snoozed; that is the point of snoozing.

**Settle.** `done` or `stopped` and unchanged for `SETTLE_AFTER` (10 minutes).
`failed` never settles. A never-before-seen finished session with no live
process settles on the first poll, because the supervisor only reaps a process
after about an hour idle, which is longer than the settle window.

## State

`~/.config/claude-inbox/state.json`, keyed by session id, atomic writes.
Holds `wake_at`, `snoozed_at`, `alias`, `last_state`, `state_since`, `last_seen`.
Entries not seen in a poll for 7 days are pruned.

## Layout

```
AgentsClient  →  Store  →  Renderer  →  App
 (shells out)   (pure)    (strings)   (terminal + key loop)
```

- `AgentsClient` is the only thing that runs `claude`. `FixtureClient` swaps in a JSON file.
- `Store` holds the last poll and the snooze table behind a mutex; rules are class methods.
- `Renderer` turns sections into an array of fixed-width strings. `Painter` diffs frames
  and repaints only changed rows.
- `App` owns the terminal, the poller thread and the peek thread, and is the only
  place that spawns a child.
- `VtScreen` is a small cursor-addressed grid used to turn the `claude logs` replay
  into readable lines for the peek pane.

## Things learned from the real CLI (2.1.273)

- `claude agents --json --all` matches the documented shape exactly. A `done`
  session can still carry a `pid` and `status: idle`.
- `claude logs <id>` is **not** plain text. It is a replay of the session's terminal
  output: cursor positioning, erase-line, colour. Words are frequently separated by
  cursor motion rather than spaces, so stripping escapes yields run-together garbage.
  Feeding it through a screen grid produces readable text.
- `claude logs` fails with "job not found" for a finished session whose process the
  supervisor has reaped. The peek pane shows a notice instead.
- `claude attach --help` confirms `←` returns to agent view, `Ctrl+Z` drops to the
  shell, and the session keeps running either way.

## Development

```
bundle install
bundle exec rake test        # minitest/spec, test/**/*_spec.rb
bundle exec standardrb
bin/claude-inbox-probe [fixture.json]   # print sections, no TUI
```
