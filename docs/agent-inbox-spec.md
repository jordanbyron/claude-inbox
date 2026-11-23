# agent-inbox

Draft spec, 2026-11-23. A Rex-native successor to claude-inbox, in a new
repository. This file moves there as its first commit.

[Problem statement](#problem-statement) · [Proposed solution](#proposed-solution) · [Decisions](#decisions) · [Terms](#terms) · [Architecture](#architecture) ·
[Agents, status and families](#agents-status-and-families) · [Triage rules](#triage-rules) · [Starting, restoring and deleting](#starting-restoring-and-deleting) ·
[Pull requests](#pull-requests) · [The watcher](#the-watcher) · [Views and verbs](#views-and-verbs) · [Recipes and config](#recipes-and-config) · [Prior art: rexuikit](#prior-art-rexuikit) ·
[What ports from claude-inbox](#what-ports-from-claude-inbox) · [Build order](#build-order) · [Alternatives considered](#alternatives-considered) ·
[Open questions](#open-questions) · [Appendix: what this rests on](#appendix-what-this-rests-on) · [Changelog](#changelog)

## Problem statement

claude-inbox asks each harness's daemon for its sessions (`claude agents
--json`, the Codex app-server) and builds an inbox on top. That made sense
when nothing else knew where the agents were. It has two costs:

- Every harness needs an adapter that can list, attach, start, stop and
  delete. Claude's and Codex's come to about 1,170 lines, and
  [cli-quirks.md](cli-quirks.md) is 279 lines of what those daemons really do.
- About 330 more lines exist so that one process owns the state while other
  front ends ask it for changes: the writer lock, the snapshot, the action
  requests and headless mode.

[Rex](https://www.superlogical.com/rex/docs/) already knows where the agents
are. An agent there is a program in a pane, the Rex server keeps it running
with no window open, and programs report their state to the terminal with a
standard escape sequence. Inside Rex most of claude-inbox is a second copy
of something the terminal does for free.

## Proposed solution

Build agent-inbox as a new Go project that requires Rex. Rex owns the list
of running agents and their status. agent-inbox owns what Rex doesn't have:
triage (needs you, unread, snooze, pin, settle), pull requests, worktrees
and a good form for starting an agent.

It is one binary with short-lived subcommands, plus one watcher process it
starts on demand:

```
agent-inbox                 the list (narrow panes get a compact layout)
agent-inbox new             the new-agent form, or flags for scripts
agent-inbox snooze|wake|pin|settle|restore|alias|link|delete [AGENT]
agent-inbox ls --json       the rows, for other tools
agent-inbox watch           the watcher (started for you)
```

To anchor the discussion, here is one agent's life:

1. You press a Rex hotkey and `agent-inbox new` opens in a floating layer.
   You type a prompt, leave Harness on Claude and press `Ctrl-O`.
2. agent-inbox creates a worktree at `<repo>/.worktrees/fix-login`, writes a
   record, and starts `claude` in a new Rex tab labelled with the agent's id.
3. Claude reports `working`, then `blocked` on a permission prompt. The
   watcher sees both. The row moves to Needs you and a notification fires.
4. You press `Enter` on the row. Rex shows the tab, the watcher marks the
   agent seen, and the row moves to Active.
5. The agent opens a pull request from its worktree's branch. The watcher
   finds it through `gh` and the row shows `#912 open`.
6. The pull request merges. The agent is idle and you aren't looking at its
   tab, so the watcher closes the tab and the row moves to Settled.
7. A week later you press `Enter` on the settled row. agent-inbox resumes
   the conversation in a new tab, in the same worktree.

## Decisions

Settled on 2026-11-23.

| Decision | Why |
|---|---|
| New repository, not a fork or a rename | The owner of the list changes from the harness daemons to Rex, which inverts the central abstraction. The name is in the gem, the module, the config directory and the pane's plugin id. |
| Rex only | Listing agents outside Rex brings the adapters back and with them most of the code this removes. |
| Go, one static binary | In Rex every hotkey starts a process, and `rex run` starts it in the login shell's environment, which already broke the Ruby launcher once. Measurements are in the appendix. |
| List every block whose status `app` matches a recipe | Build tools report status too, so the `app` key is the filter. |
| An agent started by another agent nests under it | The family is one triage unit. A blocked child puts the family in Needs you. |
| Closing a block settles; settling closes the block | Settled means no block, so Rex's tabs are exactly the live work. `Enter` on a settled row restores it. |
| One required watcher, started on demand | With an inbox split in several tabs, several observers would each record the same event and each poll GitHub. |
| The form picks the Rex session, defaulting to the current one | Rex has no notion of a project, and a silent mapping would surprise. |
| Claude and Codex built in; other harnesses by config | Each shipped recipe has to be checked against the real CLI. |
| agent-inbox owns worktrees, on by default in a git repository | A worktree that belongs to one agent is what makes pull request detection exact. |
| Worktrees default to `<repo>/.worktrees/<name>`, overridable | Easy to find. The template is there for repositories whose tools scan nested copies. |
| Pull requests come from the worktree's branches, else from `rex capture` | No transcript reading, so recipes carry no knowledge of a harness's files. |
| v1 keeps image paste and the slash menu | Both are worth a recipe field. |
| v1 drops retitle, usage bars, Remote Control, adopt, the phone page and self-update | Each is tied to one harness or to the daemon. The Claude Code pane is replaced by the list in a Rex split. |

## Terms

- **Rex session, tab, block.** Rex's own words: a session groups tabs (Rex
  calls a tab a window), and a block is one terminal in a tab.
- **Agent.** One conversation with a harness, running in a block or not
  running at all. claude-inbox called this a session.
- **Launched and found agents.** A launched agent was started by
  `agent-inbox new` and has a record. A found agent is one you started by
  typing `claude` in a Rex terminal; it is known only by its block.
- **Record.** What agent-inbox remembers about a launched agent: id,
  harness, the harness's own session id, name, directory, worktree and
  branch, parent, and when it began.
- **Family.** A launched agent plus every agent it started, however deep.
- **Recipe.** What agent-inbox knows about one harness.

## Architecture

| Process | Lives | Reads | Writes |
|---|---|---|---|
| Watcher | As long as the Rex server | Rex events, `gh`, git, state | State (what it observed, and the automatic rules), snapshot |
| List view | While on screen | Snapshot | Nothing itself; each key runs the same code as a verb |
| `new` | Until the agent starts | Recipes, Rex sessions | Record, worktree, a Rex tab |
| Verbs | Milliseconds | State | State (what you decided), and Rex when a tab closes or opens |
| `ls --json` | Milliseconds | Snapshot | Nothing |

Config is `~/.config/agent-inbox/config.toml`. State is kept per Rex server,
under `~/.local/state/agent-inbox/<server>/`:

- `state.json` holds records, triage entries and remembered pull requests.
  Every writer takes one file lock, re-reads, edits and renames into place.
  There is no single writer and no request relay.
- `snapshot.json` holds the rows as the screen shows them, already sorted
  into sections, with the watcher's version and a heartbeat. Only the
  watcher writes it.
- `watcher.lock` is held by the running watcher.

The watcher is the only process that subscribes to Rex or calls `gh`. A view
never works out a row's section, so the triage rules run in one place, as
they do in claude-inbox today.

## Agents, status and families

**Which blocks are agents.** A block is an agent when its label is
`agent-inbox:<id>` for a record we hold, or when the root status record it
reports has an `app` that matches a recipe. Everything else is ignored, so
`cargo` reporting a build never shows up.

**Identity.** A launched agent is keyed by the id in its label, which
survives restore: the new block gets the same label. A found agent is keyed
by its block id, so its snooze, pin and alias end when the block closes and
the row disappears. There is nothing to restore it from.

**Status.** Programs report with OSC 7501: `idle`, `working`, `done`,
`blocked` or `error`, plus a `kind` for a block (permission, question,
auth), a `title` and a `msg`. claude-inbox already normalises both harnesses
into these words, so the rules below use them as they are. The row's detail
line is the `msg`, as `line` is today.

A program may also report child records, such as `id=build/test`. Rex does
no roll-up, so agent-inbox does: a row is `working` while any of its records
is working, and it needs you if any record is blocked or in error. That
brings back "waiting on a sub-agent" for a harness that reports its
sub-agents this way.

A block with a record but no status yet shows as `starting`. If a harness
turns out not to report status, its recipe carries a hook that does. That is
the per-harness cost, and it stays in the recipe.

**Families.** `agent-inbox new` run from inside an agent's block finds that
block in `REX_BLOCK` and records the agent as the parent. Rex keeps no
parent for a block, so an agent started with a bare `rex run` is a found
agent with no family.

- Children draw indented under the root, flat however deep the family goes.
- The family's section follows its most urgent member.
- Snooze, pin, settle, alias and delete apply to the family. A verb aimed at
  a child acts on the root.
- `Enter` on a child shows that child's tab.
- A child whose block closed while the root lives shows as `closed` under
  it, and `Enter` restores it. The family is settled when the root is.

## Triage rules

These are `Store::Row` and `Store::Entry` carried over. Their specs are the
list of cases to port.

A row's section is the first that applies:

1. **Snoozed.** It has a wake time that hasn't passed. A snooze outranks a pin.
2. **Pinned.**
3. **Settled.** It has no block.
4. **Needs you.** It is blocked or in error, or it isn't working and its
   pull request has failing checks or changes requested, and you haven't
   seen it since that began.
5. **Working.** With `fold_working` on: it is at work and not waiting on
   something it started.
6. **Active.** Everything else.

What changes from claude-inbox:

- **Settled means no block.** `x`, closing the tab yourself and the agent's
  program exiting all end in the same place, and all three clear a snooze.
  `X` (stop) is gone.
- **Auto-settle closes the tab.** It fires when every pull request of the
  family that counts as its own is merged or closed, no member is working
  or in error, and no member's tab is the one showing in a Rex app. A pinned
  or snoozed family is left alone until it is unpinned or wakes.
- **A restore holds until a new pull request resolves.** The entry remembers
  which pull requests caused the settle, and auto-settle fires again only
  when one outside that set resolves. Today a revive lapses on the next
  state change, which here would close a tab moments after you reopened it
  to ask a follow-up.
- **Seen replaces attached.** An agent is seen while its tab is the active
  one in a connected Rex app. `acknowledged_at` and `last_visited_at` keep
  their meanings: the first moves a row out of Needs you until its state
  changes again, the second drives the unread dot.

What stays the same: a snooze wakes on its timer, on `u`, or when the agent
becomes blocked or fails. Trouble on a pull request counts as a state
change. A pull request resolved before the agent began is a mention and
never settles it. `error` is never auto-settled. Sorting, the activity sort
and the folds are unchanged.

`reap = true` in the config deletes families settled for 14 days, with the
refusals delete has. It is off by default and each deletion is logged.

## Starting, restoring and deleting

**The form** has these fields: Prompt, Harness, Name, Directory, Rex
session, Model, Effort, Permissions and Worktree.

- Rex session lists the server's sessions plus "new session", and starts on
  the one the form was opened from.
- Worktree starts on `yes` when Directory is in a git repository and is
  hidden otherwise. `worktree.default = false` flips that.
- Model, Effort and Permissions offer what the chosen recipe lists.
- The prompt keeps image paste, file drop and the `/` menu. The recipe says
  how its harness mentions a file and which directories hold its commands.
  Claude's built-in recipe also reads installed plugins, as `SlashCommands`
  does today.
- `Tab` moves between fields, `Ctrl-S` starts the agent and `Ctrl-O` starts
  it and shows its tab.
- An empty Name is filled from the prompt's first words. No model is asked.

Every field is also a flag, and with `--prompt` given no form opens. That is
how a script or another agent starts one:

```
agent-inbox new --harness codex --cwd . --session work --prompt "fix the flaky spec"
```

**Starting** runs in this order, and a failure undoes the steps before it so
nothing is left half made:

1. Write the record.
2. Create the worktree: `git worktree add` at the path template, on a new
   branch named for the agent, from `origin`'s default branch after a fetch
   (`worktree.base = "head"` branches from the checkout's HEAD instead). A
   taken name gets `-2`. A path inside the repository is added to
   `.git/info/exclude`, so nothing is committed to ignore it.
3. Start the recipe's command in a new tab of the chosen session, in that
   directory, with the block labelled `agent-inbox:<id>`, and name the tab.
4. With `Ctrl-O`, show the tab.

**Restoring** (`Enter` or `u` on a settled row) starts the recipe's resume
command in a new tab with the same label, in the same directory, and clears
the settle. If the worktree is gone it fails and says so; it does not start
somewhere else.

**Deleting** (`Ctrl-x`, then `y`) closes the family's tabs, removes its
worktrees and branches, and deletes its records and triage. A worktree with
uncommitted changes or unpushed commits stops the whole delete, and the
message names it. The harness's own transcripts are left alone.

## Pull requests

- **An agent in a worktree we own** gets the pull requests of every branch
  that has been checked out there. The worktree's own reflog lists those
  checkouts, so a stack of branches is covered without polling. `gh` finds
  the pull request for each branch.
- **Any other agent** gets the pull request links found in its terminal,
  read with `rex capture` each time it finishes a turn. This is lossy: a
  harness drawing full-screen leaves little scrollback, and a link the agent
  only mentioned is picked up too. Mentions rank below live pull requests,
  as they do today.
- **`P` links one by hand** and overrides both.

Every pull request found is remembered in the state, since a closed block
can't be captured again. The watcher refreshes the unresolved ones through
`gh` on the schedule `PullRequests` uses now, and the health rules port
unchanged. GitHub through `gh` is the only host in v1.

## The watcher

- **One per Rex server.** Every command makes sure one is running: it tries
  the lock, and if the lock is free it starts `agent-inbox watch` detached.
  The watcher leaves when the Rex server goes away.
- **Version.** The snapshot carries the watcher's version. A newer binary
  asks an older watcher to exit and starts its own.
- **Heartbeat.** The snapshot is rewritten every 5 seconds whether or not
  anything changed. A view that finds it older than 15 seconds starts the
  watcher again and says so in its header. It never shows old rows as
  current.
- **Observing.** It holds one connection to Rex and reads the events for
  the server and each session. From those it records each agent's state,
  which tab each app is showing, and which blocks closed.
- **Acting.** It applies the automatic rules: wake, auto-settle, and
  settling an agent whose block closed. With `notify = true` it sends a
  desktop notification when a family starts needing you or finishes.
- **Reacting to you.** It watches `state.json`, so a verb's edit reaches the
  snapshot at once.

## Views and verbs

**The list** is claude-inbox's screen: the same sections, row layout, folds
and filter. Below 60 columns it draws one line per row (badge, label, pull
request), which is the old Claude Code pane as a Rex split. It reads only
the snapshot.

Keys keep their claude-inbox meanings: `j` `k` `gg` `G`, the paging keys,
`Tab`, `h` `za` `zo` `zc`, `Enter` `l`, `n`, `t`, `s`, `u`, `x`, `a`, `o`,
`y`, `P`, `Ctrl-x`, `/` and `q`. `X`, `r`, `w`, `N`, `R` and `U` are gone.
`n` opens the form in a floating layer.

`Enter` focuses the agent's block and asks each Rex app showing that session
to select its tab. Rex refuses that until Remote Control is on in its
settings, and the refusal names the setting, so it goes to the status line
as it does today.

**Verbs** take an agent id, or `--block ID`, and fall back to `REX_BLOCK`.
That fallback is what lets a Rex hotkey act on the agent you're looking at
without the inbox open:

```
agent-inbox snooze 1h          # also 15m, tomorrow, until-woken, or a time
```

A verb aimed at a block that isn't an agent exits non-zero and says so.

**Rex bindings.** `agent-inbox lua` prints a snippet for `init.lua` with
actions for: the form in a floating layer, the list in a tab, the list as a
split beside the current tab (a toggle), and snooze, pin and settle for the
focused agent. The keys are the user's to choose.

## Recipes and config

A recipe, shown for Claude. The flags come from what claude-inbox passes
today and get checked again in step 0.

```toml
[recipes.claude]
app     = "claude-code"
start   = ["claude", "--session-id", "{session_id}", "--name", "{name}",
           "--model", "{model}", "--effort", "{effort}",
           "--permission-mode", "{permissions}", "--", "{prompt}"]
resume  = ["claude", "--resume", "{session_id}"]
mention = "@{path}"
commands = ["~/.claude/skills", "~/.claude/commands"]

[recipes.claude.choices]
model       = ["default", "fable", "opus", "sonnet", "haiku"]
effort      = ["default", "low", "medium", "high", "xhigh", "max"]
```

A flag whose value is `default` is left out along with its value. A recipe
in the config file with a built-in's name replaces it.

The rest of the config:

```toml
sort = "default"            # or "activity"
fold_working = false
notify = false
reap = false

[worktree]
default = true
path    = "{repo}/.worktrees/{name}"
branch  = "{name}"
base    = "fresh"           # or "head"
```

## Prior art: rexuikit

[rexuikit](https://github.com/dphaener/rexuikit) is Darin Haener's Go
toolkit for programs that run as Rex floating layers (MIT, Bubble Tea v2).
Read on 2026-11-23, when it tracked Rex API revision 7.

| Package | What it does | Where it fits here |
|---|---|---|
| `client` | One WebSocket connection to Rex, with typed methods and an event channel. A call takes 0.1-3 ms, against about 76 ms for the `rex` CLI. | The Rex client in step 2 and the watcher's event stream. |
| `surface` | Opens a program as a modal, drawer or split and reports when it closes. It can pre-warm a program so the layer appears at once. | The form as a modal; the compact list as a drawer or split. |
| `ui` | Form, list, dialog, hint bar and notice components, with golden-frame tests. | The form's plain fields, the snooze menu and the confirms. Its text area has no image paste or slash menu. |
| `entry` | Runs a quick action before the rest of the program loads, and measures time to first paint. | The verbs, and the form's startup. |

Its `docs/rex-behaviors.md` records what Rex does that the API reference
leaves out, most of it with a live test. This spec leans on these:

- A floating layer and its block go away, with `block_closed`, when the
  program exits.
- The connection that creates a block owns it, and the app won't size the
  block until that connection disowns it or closes. `new` and `restore` are
  short-lived, so they're fine. The watcher never creates a block.
- A focus change emits only `session_view_changed`. "Seen" is therefore read
  per tab, from the session's `active_window_id`.
- Lua in `init.lua` runs with the Rex server's environment, whose `PATH`
  lacks most tools (inferred there, not tested). `agent-inbox lua` writes
  the binary's absolute path into the snippet.
- A minimal Bubble Tea program paints in about 85 ms warm, and the form it
  was built for took about 390 ms. Go alone doesn't make the form instant,
  which is what warm surfaces are for.

Its snapshot of the Rex API gives the result of `program_status`: a
`records` array with `state`, `kind`, `app`, `effective_app`, `title`, `msg`
and an `updated_at` set by the server. A row's "last changed" age comes from
Rex, then, and survives a watcher restart.

## What ports from claude-inbox

| claude-inbox | Lines | In agent-inbox |
|---|---|---|
| `Store`, `Entry`, `Row`, `SnoozeTime` | ~650 | Ported to Go, re-keyed by agent id, minus the writer and relay half. |
| `PullRequests`, `StackLinks` | ~300 | Ported. Discovery changes; health and refresh don't. |
| `NewSessionForm`, `TextBuffer`, `SlashCommands`, `Images`, `Paste` | ~950 | Rewritten on Bubble Tea, with rexuikit's fields where they fit. The specs list the cases. |
| `Renderer`, `Dialog`, `Keymap`, `Theme`, `Text` | ~960 | Rewritten on Bubble Tea. `bin/screens` output is the reference. |
| `Notifier`, `Reaper` | ~180 | Ported into the watcher. |
| `Rex` and `claude-inbox attach` | ~110 | Becomes the Rex client the whole program uses. |
| `Poller`, `Snapshot`, `Headless` | ~260 | The idea survives as the watcher. The code doesn't. |
| Claude and Codex adapters, the relay, `VtScreen` | ~1,300 | Dropped. |
| `Actions`, `Switch`, `WriterLock` | ~210 | Dropped. |
| `remote/`, `mod/`, `Updater`, `Titler`, `RateLimits` | ~1,500 | Dropped. |

claude-inbox stays as it is, for people who aren't in Rex.

## Build order

Each step is one pull request unless noted. Step 0 comes first because three
later steps rest on what it finds.

0. **Spike, written up as `docs/rex-quirks.md`.** No code kept. In Rex, run
   Claude Code and Codex and record whether each reports OSC 7501, with
   which `app`, whether sub-agents show up as child records, and how much of
   each harness's output `rex capture` returns.
1. Repository, local CI with signoff as here, and the state file with the
   triage rules as table tests ported from the specs.
2. The Rex client. Try rexuikit's `client` and its fake server first.
3. The watcher: observe, write the snapshot, start on demand, heartbeat.
4. `ls --json` and the verbs.
5. The list view, then its compact layout.
6. Recipes, `new` with flags only, and worktrees.
7. The form, in three pull requests: fields, prompt editor, paste and menu.
8. Pull requests: worktree branches, the capture fallback, auto-settle.
9. Families.
10. Notifications, reap, the Lua snippet and the README.

## Alternatives considered

- **Adapt claude-inbox in place.** Every change would have to keep the
  daemon world working too, and the name would be wrong either way.
- **Stay in Ruby.** Lazy requires get a verb to about 150 ms, a budget to
  defend forever, and the launch environment stays fragile.
- **No watcher, with views observing.** Fine with one view. With a split in
  every tab it means duplicate observations, duplicate `gh` polling and an
  unread dot that is wrong whenever no inbox is on screen.
- **One small binary per job.** Each would need to know the state file's
  format. One binary with subcommands gives the same interface without
  spreading that knowledge.

## Open questions

1. Do Claude Code and Codex report OSC 7501 inside Rex today? Rex's docs
   name no adopters. If either doesn't, how small a hook makes it? (Step 0.)
2. Do we depend on rexuikit or only read it? I'd take `client` and
   `surface`, which hold Rex behaviour we would otherwise measure again, and
   try `ui` for all but the prompt editor. The risk is one maintainer on a
   beta Rex.
3. Is there a way to get every block's status in one call? None is
   documented, so the watcher asks each block once at startup.
4. Rex's roadmap lists "a unified priority inbox view". If it ships, how
   much of the list do we keep? Triage, pull requests and worktrees are the
   parts least likely to be covered.
5. Should a found agent become a launched one on first triage, by labelling
   its block and writing a record? Left out of v1 because we can't learn the
   harness's session id from outside, so it could never be restored.
6. How should a fresh worktree get the files git doesn't track (`.env`,
   installed dependencies)? A per-repository setup command is the obvious
   answer and isn't in v1.

## Appendix: what this rests on

**From Rex's docs**, read 2026-11-23. About three quarters of the full docs
text was not read.

- Program status is OSC 7501. Each report replaces its record. `working` and
  `blocked` clear when the process exits; `done` and `error` survive.
- `rex capture` returns a block's screen and scrollback as text.
- A block has no documented parent, and Rex has no notion of a project.

**From claude-inbox on Rex 0.1.0**, in [cli-quirks.md](cli-quirks.md): `rex
run` starts its command in the login shell's environment, and the app only
changes tab through its `session.select` action, with Remote Control on.

**Startup, measured here**, median of five runs: `/usr/bin/true` 8 ms,
`ruby -e ''` 108 ms, Ruby loading only `claude_inbox/store` 147 ms, Ruby
loading the whole app 590 ms, and about 200 ms more through the asdf shim.

**Checked in `claude --help`:** `--session-id <uuid>`, `--resume` and
`--name` exist. **Not checked:** Codex's flags, whether either harness
reports status in Rex, and what `rex capture` returns for them.

## Changelog

- 2026-11-23: first draft, then rexuikit added as prior art.
