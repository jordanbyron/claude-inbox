# claude-inbox

Inbox-style triage on top of Claude Code's background sessions. A companion to
`claude agents`, not a replacement: it reads the same daemon state through
`claude agents --json` and adds snooze, auto-settle and the session's pull
request.

![claude-inbox with one working session, one snoozed and the settled section folded](docs/screenshot.png)

## Install

```
gem install claude-inbox
claude-inbox
```

Requires Ruby 3.2+ and a `claude` on PATH with the agents feature. Versions
are published to rubygems and listed under GitHub Releases.
`claude-inbox --version` prints the installed version.

## Sections

1. **Pinned.** Parked at the top by hand, regardless of state. `t` toggles it.
2. **Needs you.** `blocked` or `failed`, until you attach to it (see
   Acknowledge below).
3. **Active.** `working`, recently finished sessions that haven't settled yet,
   interactive sessions, and a needs-you session you've attached to that
   hasn't resolved. Interactive sessions report only `status`, so it gets
   mapped: busy is working, idle is done, waiting needs you. The daemon calls
   a terminal you opened yourself, a Remote Control worker, a sub-agent and a
   headless `claude -p` run all "interactive"; the inbox tells them apart from
   the process tree. Sub-agents and headless runs are dropped, since nobody is
   sitting in them. Remote sessions settle and snooze like any other row. A
   terminal you are sitting in never settles, and none of these can be
   attached, peeked or stopped from outside; Enter tells you so.
4. **Snoozed.** Sorted by wake time, parked ("until I wake it") entries last.
   Collapsed; Enter expands.
5. **Settled.** Parked with `x`, or whose pull request is merged or closed.
   Collapsed; Enter expands.

A row with a pull request shows it after the state: `#885 open`, `#885 draft`,
`#885 merged`, `#885 closed`. `o` opens it in the browser.

`working` from the daemon covers two situations, and the row says which. A
spinner and `working` mean the agent is thinking. A steady `◌` and `idle · 1
shell` mean the agent has stopped and is waiting on work it started, such as a
`--watch` shell or a sub-agent. That is why a session with nothing left to do
can sit there for an hour. The open work is named next to the state either
way: `working · 2 agents`, `idle · 1 shell`.

Under each row in Pinned, Needs You and Active is the line `claude agents`
prints too: what it is waiting on while blocked (`↳ confirm: drop the top
line?`), what it produced once done, otherwise its status line. A terminal you
opened yourself has none and shows its directory instead.

A session you gave a color to with `/color` wears it on the label. Nothing
else is tinted, so a blocked session still looks blocked.

## Keys

Vim bindings; arrows work as well as `j`/`k`. The mouse works too, in
terminals that report it: clicking a row selects and attaches, and the wheel
moves the selection. Apple Terminal reports neither, so there the wheel
scrolls its own history and clicks do nothing.

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
| `n` | new session (see below) |
| `t` | pin / unpin |
| `s` | snooze: `1` 15m · `2` 1h · `3` tomorrow 9am · `4` until woken |
| `u` | wake a snoozed session now, or bring back one you settled |
| `x` | settle a working or needs-you session by hand (returns when it changes state, unless it just finished) |
| `a` | set a local alias (never touches the real session name) |
| `o` | open the session's pull request in the browser |
| `P` | link a pull request by hand (empty clears; the scanned links return) |
| `X` | stop the session (`y` to confirm) |
| `Ctrl-x` | delete the session for good, conversation and worktree with it (`y` to confirm) |
| `/` | filter by name, cwd, the prompt it started from, or what it is doing now; `Enter` keeps it, `Esc` clears |
| `R` | poll now |
| `q` | quit |

`X` and `Ctrl-x` both ask first, and both take `y`, but they are not the same
thing. `X` runs `claude stop`: the process ends, the conversation is kept, and
`Enter` resumes it later. `Ctrl-x` runs `claude rm`: the session, its
transcript and its worktree all go. Nothing resumes afterwards, so read the
box before answering.

### New session

`n` opens a form: prompt, name, directory, model, effort, permissions,
worktree. `Tab` / `Shift+Tab` move between fields, `Esc` cancels. Choice
fields cycle with `h` `l` or the arrows; "default" shows what your settings
resolve to. The directory defaults to the selected row's, and `Tab` completes
it.

`Ctrl-S` starts the session and drops you back in the inbox; `Ctrl-O` starts
it and attaches. Either way the new row is selected once it shows up. It runs
`claude --bg "<prompt>"` in that directory, with only the flags you changed.

The prompt is multi-line; `Enter` breaks a line. Paste an image with `Cmd-V`
(or `Ctrl-V`), or drop a file onto the window, and it lands at the cursor as
an `[Image #1]` token the prompt can point at: "make the button look like
[Image #1]". Pasted images are saved under `~/.config/claude-inbox/images/`
for 14 days; a dropped file is referenced where it is. Reading the clipboard
is macOS only.

Slash commands work as at Claude Code's own prompt. Type `/` at the start of a
word for a menu of your skills and commands, plugin skills as `plugin:name`,
claude.ai's synced skills as `anthropic-skills:name`. `↑` `↓` choose, `Tab` or
`Enter` insert, `Esc` closes the menu. Built-ins such as `/init` aren't listed
but still work.

## How sessions move

**Wake.** A snoozed session returns when its timer elapses, when you press
`u`, or when it becomes blocked or failed after being snoozed. A session that
was already blocked when you snoozed it stays snoozed; that is the point of
snoozing. `u` also brings back a settled row and puts it wherever its raw
state belongs.

**Acknowledge.** Attaching to a needs-you session marks its current state
seen and moves it to Active. It comes back to Needs You when its state
changes again. Still blocked with a new prompt doesn't count.

**Settle.** Settled by hand with `x`, or because every pull request it has is
merged or closed. A hand-settled session stays put when it finishes, and
returns as soon as it changes state in any other way. `failed` never settles.
A session with no pull request never settles on its own, however long it has
been quiet. A session with one stays Active while any of its PRs is open or a
draft.

**Reap.** A background session quiet for 14 days is deleted on the next poll
with `claude rm`, so the transcript and the worktree go with it, same as
`Ctrl-x`. This is the one thing here that destroys anything without asking
first. Reaping does not key on Settled: an open draft keeps a row in Active
for ever, and those are precisely the rows that need reaping. Idle time is the
only clock.

Never reaped, whatever the clock says: a `working` session, one that still
holds a process, a pin, and a snooze. `failed` is reaped, even though it never
settles; after a fortnight of not looking at it you never will. A pin or a
parked snooze is the way to keep a session indefinitely.

Unpushed work is safe. `claude rm` refuses a worktree holding commits that
aren't pushed, and nothing here ever overrides that refusal. Every reap
appends a line to `~/.config/claude-inbox/reaped.log`, the last record a
session existed once its transcript is gone. `CLAUDE_INBOX_NO_REAP=1` turns
reaping off.

## Pull request state

The daemon scans each background session's transcript for PR links, so a
session that only reviews a PR gets it too. Interactive sessions aren't
scanned; `P` sets the link by hand for those, or to correct a bad scan.

State comes from whatever Claude Code last saw, then `gh pr view` on the
poller thread, at most once a minute per PR. Without `gh` the cached state is
all you get. The list goes up before gh is asked, so the inbox is up in under
a second.

## Setup

The right end of the header shows how much of your Claude subscription's
5-hour and 7-day rate limit windows you have used, as a ten-cell bar per
window (`5h ██░░░░░░░░ 24%  7d ████░░░░░░ 41%`) that turns yellow at 70% and
red at 90%, like the context bar many status lines draw. It needs a Pro or
Max account and a one-time setup.

Claude Code passes the numbers to your [status line](https://code.claude.com/docs/en/statusline)
script every turn, and the inbox reads them from a file that script writes.
Put these two lines in the script, just after it reads stdin:

```bash
input=$(cat)
limits=$(echo "$input" | jq -c '.rate_limits // empty')
[ -n "$limits" ] && echo "$limits" > ~/.claude/rate_limits.json.tmp && mv ~/.claude/rate_limits.json.tmp ~/.claude/rate_limits.json
```

If you have no status line script, run `/statusline` in any session and it
writes one for you, then add the lines to that. Keep the `-n` check: a
session's first status line run has no numbers yet, and writing anyway would
blank the file.

The bars stay off until the file exists, and goes off again once the file
is more than fifteen minutes old.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
