# claude-inbox

Inbox-style triage on top of Claude Code's background sessions. A companion to
`claude agents`, not a replacement: it reads the same daemon state through
`claude agents --json` and adds **snooze**, **auto-settle** and the session's
**pull request**.

![claude-inbox with one working session, one snoozed and the settled section folded](docs/screenshot.png)

```
bin/claude-inbox                       # live
bin/claude-inbox --fixture test/fixtures/agents.json   # no daemon needed
```

Requires Ruby 3.2+ and a `claude` on PATH with the agents feature.

## Sections

1. **Pinned.** Parked at the top by hand, regardless of state. `P` toggles it.
2. **Needs you.** `blocked` or `failed`, unless you've attached to it since (see
   Acknowledge below).
3. **Active.** `working`, plus recently finished sessions that have not settled
   yet, plus interactive sessions, plus a needs-you session you've attached to
   but that hasn't resolved. Interactive sessions report only `status`, so it
   gets mapped: busy is working, idle is done, waiting needs you. The JSON calls
   a terminal you opened yourself, a Remote Control worker, a sub-agent and a
   headless `claude -p` run all "interactive", each named after its directory;
   the client tells them apart from the process tree (a remote worker runs with
   `--sdk-url` under a `claude rc` parent, a sub-agent has a `claude` for a
   parent, and a headless run gives itself away with `-p` or the SDK's stream
   flags, since the shell that spawned it hides the session behind it).
   Sub-agents and headless runs are dropped: nobody is sitting in them and
   attach lands on whatever asked for them. Remote sessions settle and snooze
   like any other row. A terminal you are sitting in never settles. Neither
   can be attached, peeked or stopped from outside; you can land on them, and
   Enter tells you why nothing happens.
4. **Snoozed.** Sorted by wake time, parked ("until I wake it") entries last.
   Collapsed; Enter expands.
5. **Settled.** Parked with `x`, or whose pull request is merged or closed.
   Collapsed; Enter expands.

A row with a pull request shows it after the state: `#885 open`, `#885 draft`,
`#885 merged`, `#885 closed`. `o` opens it in the browser.

`working` from the daemon covers two situations, and the row says which. A
spinner and `working` mean the agent is thinking. A steady `◌` and `idle · 1
shell` mean the agent has stopped and is only waiting on work it started, such as
a `--watch` shell or a sub-agent. That is why a session with nothing left to do
can sit there for an hour. Whatever the agent is up to, the open work is named
next to the state: `working · 2 agents`, `idle · 1 shell`. The count comes from
the session's own job file, which `claude agents --json` does not expose; the
inbox still takes the state itself from the daemon, the only thing that knows
whether a session is alive.

A session you gave a color to with `/color` wears it on the label — see
[Colors](#colors).

## Keys

Keyboard-first, vim flavoured, but the mouse works too. Arrows work as well
as `j`/`k`. Clicking a row does what landing on it and pressing `Enter`
would: selects it and attaches (or expands a fold, or refuses on a terminal
row you can't be attached to from here). The wheel moves the selection
rather than uncovering the scrollback behind us, in terminals that report
mouse events (`\e[?1000h` + `\e[?1006h`, the same mode clicks use) or that at
least support alternate scroll mode (`\e[?1007h`, wheel-as-arrows only, no
clicks). Apple Terminal supports neither escape, so there the wheel scrolls
its own history and clicking a row does nothing.

| Key | Action |
|---|---|
| `j` `k` | move down / up |
| `gg` `G` | first / last row |
| `Ctrl-d` `Ctrl-u` | half page down / up (`Ctrl-f` `Ctrl-b` full page) |
| `Enter` `l` | attach (full-screen handoff; `←` or `Ctrl+Z` return here), or expand Snoozed / Settled |
| `Tab` `Shift+Tab` | jump to the next / previous section |
| `h` | close the peek pane, else collapse the current Snoozed / Settled fold |
| `za` `zo` `zc` | toggle / open / close the Snoozed or Settled fold under the cursor |
| `p` | toggle the read-only peek pane |
| `J` `K` (`Ctrl-e` `Ctrl-y`) | scroll the peek pane |
| `n` | new session (full screen): multi-line prompt (`Enter` breaks a line, `Cmd-V` or `Ctrl-V` pastes an image, `Ctrl-S` starts it, `Ctrl-O` starts and opens it), name, directory (`Tab` completes), model, effort, permissions, worktree; "default" choices show what your settings resolve to |
| `t` | pin / unpin (parks it in Pinned at the top, regardless of state) |
| `s` | snooze: `1` 15m · `2` 1h · `3` tomorrow 9am · `4` until woken |
| `u` | wake a snoozed session now, or bring back one you settled |
| `x` | settle a working or needs-you session by hand (returns when it changes state, unless it just finished) |
| `a` | set a local alias (never touches the real session name) |
| `o` | open the session's pull request in the browser |
| `P` | link a pull request by hand (empty clears; the scanned links return) |
| `X` | stop the session (`y` to confirm) |
| `Ctrl-x` | delete the session for good, conversation and worktree with it (`y` to confirm) |
| `/` | filter by name or cwd; `Enter` keeps it, `Esc` clears |
| `:q` | quit (`:peek`, `:refresh`, `:pr`, `:pin` also exist) |
| `R` | poll now |
| `q` | quit |

Bindings live in `ClaudeInbox::Keymap`, a pure resolver with chord support
that is unit tested on its own. A fast `Esc` followed by `:` is split back
into two keys, since tty-reader would otherwise glue them together.

`X` and `Ctrl-x` both ask before they act, and both take `y`, but they are not
the same thing. `X` runs `claude stop`: the process ends, the conversation is
kept, and `Enter` resumes it later. `Ctrl-x` runs `claude rm`. The session,
its transcript and its worktree all go, and so does our own state entry for
it, rather than sitting out the seven-day prune. Nothing resumes afterwards,
so read the box before answering.

### New session

`n` opens a form. `Tab` / `Shift+Tab` move between fields, `Enter` moves on
(inside the prompt it breaks a line), `Esc` cancels. Choice fields cycle with
`h` `l` or the arrows. Text fields are a real editor: `←` `→` move the cursor,
`Ctrl-A` / `Ctrl-E` jump to the ends, `Backspace` and `Delete` cut either side
of it, `Ctrl-W` takes the word before it and `Ctrl-U` / `Ctrl-K` everything
before / after it.

`Ctrl-S` starts the session and drops you back in the inbox; `Ctrl-O` starts it
and hands the terminal straight over. Either way the new row is selected once
it shows up. Terminals send the same byte for `Ctrl-S` and `Ctrl-Shift-S`, so
the second start needs a letter of its own.

The directory defaults to the selected row's. It runs `claude --bg "<prompt>"`
with only the flags you changed from default, in that directory.

Images work as they do at Claude Code's own prompt. Paste one with `Cmd-V`
(or `Ctrl-V` in a terminal that doesn't do bracketed paste), or drop a file
onto the window, and it lands at the cursor as an `[Image #1]` token that
moves and deletes as one character, so the prompt can point at it: "make the
button look like [Image #1]". On macOS, `Cmd-Ctrl-Shift-4` copies a region of
the screen; `n` and `Cmd-V` put it in the prompt. A pasted image is saved
under `~/.config/claude-inbox/images/` (cleared after 14 days, as sessions
are); a dropped file is referenced where it is. When the session starts, each
token becomes an `@path` mention, which `claude` reads as an image the way it
does at its own prompt. A dropped file that isn't an image, and pasted text,
stay text, newlines included.

Why the terminal can paste an image at all: with bracketed paste on, a paste
arrives fenced between `\e[200~` and `\e[201~`, and an image, having no text
form, arrives as an empty fence. That empty fence is the signal to read the
clipboard, which is how Claude Code does it too. A dropped file arrives the
same way, as its shell-escaped path. Reading the clipboard goes through
`osascript`, so it is macOS only; elsewhere the paste is reported empty.

Slash commands work as they do at Claude Code's own prompt: a prompt that
starts with one, `/unslop README.md`, is expanded by `claude` into the skill
with its arguments before the session starts; one further into the text is
left for the agent to read and act on. Typing `/` at the start of any word
opens a menu of what the CLI would offer — project and personal skills and
commands, plugin skills as `plugin:name`, claude.ai's synced skills as
`anthropic-skills:name` — narrowed as you type, each with the description
from its front matter. `↑` `↓` choose, `Tab` or `Enter` drop the command in
with a space after it, `Esc` closes the menu (a second `Esc` cancels the
form). A `/` inside a word, as in `a/b`, opens nothing, and the menu only
appears while something matches, so a path like `/Users/…` is left alone
after its first letters. Built-ins such as `/init` live inside the CLI and
are not listed; typing one still works. Project commands follow the
Directory field.

### Why `←` comes back here and not to native agent view

Inside an attached session, `←` on an empty prompt detaches. `claude attach`
then execs itself in place as `claude agents`, so you would land in the native
view and only get back to the inbox after quitting that. No flag or setting
suppresses just that relaunch: the one switch that exists disables `attach`
too. So the inbox watches its child's command line and, the moment it turns
into the agents view, terminates it. Measured round trip is about 0.4s and the
agents view never draws a frame. `Ctrl+Z` is handled locally by the attach
client and returns directly with no trick needed.

## Rules

All four rules are pure methods on `ClaudeInbox::Store::Row`, a session paired
with its entry, and are the only place triage logic lives.

**Wake.** A snoozed session returns when its timer elapses, when you press `u`,
or when it *becomes* blocked or failed after being snoozed. A session that was
already blocked when you snoozed it stays snoozed; that is the point of snoozing.
`u` also brings back a settled row, whether it settled by hand or because its
pull request resolved, and puts it wherever its raw state belongs — Active or
Needs You. It stays there until the state actually changes again.

**Acknowledge.** Attaching to a needs-you session (`Enter`) marks its current
state seen, moving it to Active instead of leaving it in Needs You. It comes
back to Needs You the moment its state changes again. Still blocked with a
new prompt doesn't count, only an actual state change does, same as hand-settle.

**Settle.** Settled by hand with `x`, or because every pull request it has is
merged or closed. A hand-settled session stays put when it finishes, and
returns as soon as it changes state in any other way: working again, blocked,
or failed. `failed` never settles. A session with no pull request at all
never settles on its own, however long it has been quiet — `x` is the only
way in.

A session with a pull request follows the PR instead: it stays Active while
any of its PRs is open or a draft, however long it has been quiet, and
settles the moment every one is merged or closed. A PR whose state is not
known yet (no `gh`, offline) is ignored, so the session stays Active too.

**Reap.** A background session quiet for `REAP_AFTER` (14 days) is deleted
outright on the next poll: `claude rm`, so the transcript and the worktree go
with it, same as `Ctrl-x`. This is the one thing here that destroys anything
without asking first, so read the rest of this before you leave it running.

Reaping does *not* key on Settled, deliberately. Settling answers "should I
still be looking at this?", and the PR rule keeps a row in Active for as long
as a pull request stays open, so an abandoned draft parks a session there for
ever and the deadest rows in the list are precisely the ones Settled never
reaches. Idle time, measured from `state_since`, is the only clock.

Four things are never reaped, whatever the clock says: a `working` session, one
that still holds a process, a pin, and a snooze. `failed` *is* reaped, even
though it never settles. It earns a permanent row because you ought to see it,
and after a fortnight of not seeing it you never will. A pin or a parked
snooze ("until I wake it") is the way to keep a session indefinitely; both are
deliberate gestures, so both outrank the reaper.

Unpushed work is safe without us doing anything. `claude rm` refuses a worktree
holding commits that aren't pushed and offers a `--discard-unpushed` token to
override it; nothing here ever passes that token, so a refusal is the end of
it. Refusals are logged and retried at most once a day.

Every reap appends a line to `~/.config/claude-inbox/reaped.log`, which is the
last record a session existed once its transcript is gone. If that file can't
be opened the sweep raises and nothing is deleted. `CLAUDE_INBOX_NO_REAP=1`
turns the whole thing off, and `--fixture` runs never reap.

## Pull requests

Claude Code already links sessions to PRs. The daemon scans each background
session's transcript for links and writes them to
`~/.claude/jobs/<id>/state.json` as `children` (`kind: "pr"`); `claude agents
--json` does not expose that, so `JobState` reads the file. It is a link
scan, so a session that only *reviews* a PR gets it too. Interactive sessions
have no job file, so for them (or to correct a bad scan) `P` sets the link by
hand; that lives in our own state file as `pr` and replaces the scanned list.

State is seeded from `~/.claude/gh-pr-status-cache.json`, whatever Claude Code
last saw, then refreshed with `gh pr view` on the poller thread, at most once a
minute per PR and never for one already merged or closed. Without `gh` the
cached state is all you get.

`gh pr view` is a network round trip, so each poll publishes the list first,
with whatever states are already known, and asks gh afterwards; the rows come
round again only if an answer moved one. That is why the inbox is up in well
under a second rather than after a dozen serial `gh` calls. Once gh has said a
PR is merged or closed the answer is kept in `~/.config/claude-inbox/prs.json`,
in the same shape as Claude Code's cache, because that cache only covers PRs
its own sessions opened and a link scan picks up plenty of others — without
the file every launch would ask about every merged PR again.

Until the first poll lands the body is blank rather than claiming "nothing
running"; past a second and a half it gets a spinner and a rotating excuse
with the elapsed time, and past ten seconds a hint to check the daemon.

## Colors

`/color` inside a session is the only way to set one; there is no key for it
here, and nothing is stored on our side. The daemon writes it to the job file
as `color`, `claude agents --json` leaves it out, so `JobState` reads it on
every poll and a color you change shows up on the next one.

It lands on the label and nowhere else. The glyph, the state badge and the PR
badge keep the colors their own state gives them, so no color you pick can
stop a blocked session looking blocked. Settled rows stay dim — that section is
meant to be quiet, and a color shouting out of a collapsed fold would undo it.

The eight colors `/color` offers are mapped the way Claude Code's own tmux
code maps them when it tints a teammate pane: `red`, `blue`, `green`, `yellow`,
`purple` and `cyan` go to the terminal's own ansi colors, so they follow your
theme; `orange` and `pink` have no ansi name and go through 256-color indexes
208 and 205. Anything else is left unpainted. Colors close with SGR 39
(default foreground) rather than 0, so a label that is already bold or italic
stays that way.

## State

`~/.config/claude-inbox/state.json`, keyed by session id, atomic writes.
Holds `wake_at`, `snoozed_at`, `alias`, `pr`, `pinned`, `pinned_at`, `settled_at`, `acknowledged_at`, `revived_at`, `last_state`, `state_since`, `last_seen`,
and `reap_failed_at` / `reap_error` for a session `claude rm` has refused.
`Store::Entry` is where those names live; everything else reads an entry
through it. Entries not seen in a poll for 7 days are pruned. Pruning only reaches entries
the daemon has *forgotten*, which is a different thing from the reaper: the
daemon still lists sessions a month old, so those keep their entry and it is
the 14-day reap that clears them.

## Layout

```
Sessions.load: AgentsClient → JobState → PullRequests  →  Poller  →  Store  →  Renderer  →  App
               (shells out)   (jobs dir)  (known states)  (thread, then gh)  (pure)  (strings)  (terminal + key loop)
```

- `AgentsClient` is the only thing that runs `claude`. `FixtureClient` swaps in a JSON file.
- `Sessions.load` is the one place the list is put together: `AgentsClient`,
  then `JobState`, then `PullRequests#enrich`, in that order because the links
  `PullRequests` wants are the ones `JobState` read. `Session` is immutable; a
  step that adds something hands back a copy.
- `JobState` reads `~/.claude/jobs/<id>/state.json`, the daemon's own file: the scanned
  links `PullRequests` wants, the open work behind a `working` state, and the `/color`
  each session carries. Never cached. `enrich` returns each background session
  with its file attached, for `Sessions.load`.
- `PullRequests` pairs each session with the PRs its `job_state` links and keeps
  their state fresh through `gh`. `enrich` never asks gh and runs inside
  `Sessions.load`; `refresh` is the slow half and runs after the list has gone
  up. `--fixture` points it at `test/fixtures/jobs` with `gh` off.
- `Palette` maps a session color to an escape sequence and knows nothing else.
- `Store` holds the last poll and the entry table behind a mutex, and folds each poll in.
  `Store::Entry` is what is remembered about one session, and the only place the state file's key names appear.
  `Store::Row` is one session with its entry, and the rules are its methods.
  `Store::Sections` is one poll sorted into sections and knows where the cursor can land: the `/` filter, the fold-or-rows rule and which section a key is in live there.
- `Renderer` turns sections into an array of fixed-width strings. `Painter` diffs frames
  and repaints only changed rows.
- `Reaper` runs `claude rm` over whatever `Row#reapable?` picks and appends a
  line to the log for each one. `due` names them without touching anything;
  `sweep` does the deleting. Both run on the poller, and the list goes up
  between them, so a slow `rm` stalls neither a frame nor the first one.
- `Poller` is the thread that asks `Sessions.load` for the list, every four
  seconds and on demand, runs it past the `Reaper` and then the gh refresh,
  and hands each result to `App` over a queue. `App` pauses it while `claude
  attach` has the terminal.
- `Terminal` is the screen: the alt screen with its mouse and wheel modes, raw
  mode, the cached size and the `Painter` that diffs frames onto it. `release`
  lends it to `claude attach` and takes it back.
- `App` owns the key loop, the poller thread and the logs thread, and is the
  only place that spawns a child.
- `Peek` is the peek pane: whether it is open, how far back it is scrolled and
  what to paint for the selected row. `Logs` is where the lines come from: the
  `claude logs` replay of each session, fetched off the main thread, debounced
  and cached.
- `VtScreen` is a small cursor-addressed grid used to turn the `claude logs` replay
  into readable lines for the peek pane.
- `SlashCommands` reads the skills and commands `claude` would offer from the
  same directories it reads them, front matter included, for the new-session
  prompt's menu. Pure filesystem; it never runs `claude`.
- `Dialog` is a box over the list that claims every key until it answers:
  the snooze menu, the stop and delete confirms, the alias and pull request
  prompts. Pure, like `NewSessionForm`; `App` acts on the answer.
- `Mouse` turns the SGR escape sequences the terminal sends for clicks and
  wheel ticks into `Event`s; `App` maps a click's row back to whatever
  `Renderer` painted there.

## Things learned from the real CLI (2.1.273)

- Terminal.app puts the tty's active process in the tab title, so a poller that
  forks `claude` every few seconds makes the title flicker. Every helper
  subprocess here is started with `setsid` so it has no controlling tty.

- `claude agents --json --all` matches the documented shape exactly. A `done`
  session can still carry a `pid` and `status: idle`.
- `claude logs <id>` is **not** plain text. It is a replay of the session's terminal
  output: cursor positioning, erase-line, color. Words are frequently separated by
  cursor motion rather than spaces, so stripping escapes yields run-together garbage.
  Feeding it through a screen grid produces readable text.
- `claude logs` fails with "job not found" for a finished session whose process the
  supervisor has reaped. The peek pane shows a notice instead.
- `claude attach --help` says `←` returns to agent view and `Ctrl+Z` drops to the
  shell. Under the hood `←` makes the attach process exec `claude agents` in place,
  same pid, using its own executable path, so a PATH shim never sees it.
- `CLAUDE_CODE_DISABLE_AGENT_VIEW=1` disables `agents`, `attach` and `logs` alike.
- A prompt beginning with a slash command is expanded, `$ARGUMENTS` and all,
  in `-p` and `--bg` alike (checked on 2.1.274 with a project command).
  Installed plugins are listed in `~/.claude/plugins/installed_plugins.json`,
  keyed `name@marketplace`, each pointing at its `installPath`; claude.ai's
  synced skills sit in `~/.claude/skills/synced/<bucket>/<name>/SKILL.md`
  and show up as `anthropic-skills:<name>`.
- Interactive sessions (a `claude` you started in a terminal yourself) appear in
  the JSON with no `id` and no `state`, only `status`, and cannot be attached,
  peeked or stopped from outside.
- `~/.claude/jobs/<id>/state.json` is where the daemon keeps what the JSON
  leaves out: `children` (scanned PR and issue links), `intent`, `worktreePath`,
  `worktreeBranch`, token count and the transcript path. `~/.claude/gh-pr-status-cache.json`
  is keyed by PR url and calls an open draft `DRAFT`; `gh pr view` reports
  `OPEN` plus `isDraft`.

- The job file is also where `/color` ends up, as `color`. `claude agents --json`
  does not carry it, so a color is only ever visible by reading the file. The CLI
  offers eight, and its own tmux code is the authority on what they mean to a
  terminal: six are ansi names, `orange` and `pink` are 256-color indexes 208 and
  205. Interactive sessions have no job file and so never have a color.

## Development

```
bundle install
bin/ci                       # full signoff: lint, gem audit, tests (see CONTRIBUTING.md)
bundle exec rake test        # minitest/spec, test/**/*_spec.rb
bundle exec standardrb
CLAUDE_INBOX_STDERR=/tmp/err.log bin/claude-inbox   # crash traces off the alt screen
DEBUG=1 bin/claude-inbox                            # slow-frame notes in /tmp/inbox-debug.log
CLAUDE_INBOX_NO_REAP=1 bin/claude-inbox             # never delete an idle session
```
