# Architecture review, September 2026

A review of `lib/` as of commit 9a8214a, against the questions in
*A Philosophy of Software Design* (are the modules deep, is information
hidden, is anything decomposed by time rather than by knowledge) and the
rich-model view that behaviour belongs on the value it describes. The
recommendations are ordered by how much simpler the system gets per unit of
work. Each is a PR of its own; the table at the end tracks them.

## What is strong

- **Deep modules where it matters.** `Subprocess`, `VtScreen`, `TextBuffer`,
  `Keymap`, `Paste` and `Mouse` each hide a lot of terminal lore behind two or
  three methods. `Reaper` is the model case: one destructive operation, one
  log, and refusals are survivors rather than exceptions.
- **The store's key names stay in one file.** Nothing outside `store.rb`
  spells `"settled_at"`.
- **The README is the design document.** The Rules and Layout sections are the
  interface comments written before the code. Keep them moving with the code.

## Recommendations

### 1. Make Row the domain object and put the rules on it

The triage state of a session was a string-keyed hash called `entry`, and the
rules were `Store` class methods taking `(session, entry, now)`. `Row` already
paired the two but only exposed accessors, so callers such as the reaper built
a Row only to unpack it again.

Two designs were compared. Wrapping the class methods in a `Triage` module
changes little and still passes session and entry around in pairs. Moving the
predicates onto `Row` keeps them pure, since Row is a value, and lets
`sectionize` become a group-by. The second was chosen.

### 2. Stop mutating Session through the enrichment pipeline

`AgentsClient` sets `origin`, then `JobState.enrich` sets `job_state`, then
`PullRequests.enrich` sets `prs`, and a comment says the order matters. That is
temporal decomposition, and the `map(&:dup)` in `Poller#publish` exists only
because a later step mutates what an earlier one handed out.

Turn `Session` into `Data.define` and have each enricher return new sessions
via `with`. Ruby 3.2 is already the floor. Then collapse the three enrichers
into one loader that owns the order, so the poller no longer knows it.

### 3. Give Poller one worker and a wake signal

`soon` spawns a fresh thread per call and `once` is also called from App's
background threads, so two polls can overlap and publish out of order. Replace
the sleep loop with one thread blocking on a queue with a timeout; `soon`
pushes a token; `pause` and `resume` use the same mechanism; nothing in App
calls `once`.

### 4. Define the reap flicker out of existence

`Poller#once` publishes, sweeps, then publishes again minus the reaped keys.
The root cause is that `Store#update` resurrects any entry named in the list.
If `forget` left a tombstone that `update` honoured until the daemon's list
stopped naming that key, the poller would be list, enrich, publish, sweep,
refresh, and the second publish would go.

### 5. Route all cross-thread state through the queue

Poller sends notices over the queue, but App's `in_background` blocks call
`notice` and set `@pending_select` directly from a worker thread. Make them
push `[:notice, msg]` and `[:select, id]` and let `drain_queue` apply both.

### 6. Drop the dead peek message

`Logs#worker` pushes `[:peek, id, lines]` onto the shared queue and
`App#drain_queue` has no branch for it. `Peek` reads the cache directly, which
is right. Remove the queue parameter from `Logs`.

### 7. Collapse the three line editors into one

`TextBuffer#press`, `Dialog::Prompt#press` and `App#handle_line_key` each
implement "append a printable character, backspace deletes one". `TextBuffer`
is the complete one; the other two should hold one.

### 8. Name the selection

`@selected` is either a session key or a section symbol, and three places test
which. `Renderer::Item` already models this with `kind`. Store a selected item,
or a small cursor value with `row?` and `fold?`. The comment in `jump_section`
about ids versus keys is a wart from this.

### 9. Narrow Renderer#frame

It takes fourteen loosely typed options in a hash. A view struct built by App
would make the contract visible and let the spec construct one.

### 10. Small things

`Images` requires `store.rb` for one constant. `App#open_pr` spawns a bare
thread rather than using `in_background`. `app_screen_spec.rb` reaches into
App through `instance_variable_get` and `send` dozens of times; once items 3,
5 and 8 land, make `handle_input` and `perform` public and drive it by keys.

### Not changing

Dialog and NewSessionForm draw themselves; that is one convention and each
owns its look. The reaper stays armed only in the launcher. The rules stay
pure functions of `now`.

## Checking a refactor did not change the screen

The unit specs cover the rules and the renderer, but a structural refactor can
still move a row or a badge without failing one. `bin/screens` runs the real
binary in a pty against the committed fixture, types a key script that
exercises every section, fold, rule and modal, and prints the screen after
each step through `VtScreen`. Run it on `main` and on the branch and diff:

```
bin/screens > /tmp/main.txt          # on main
bin/screens > /tmp/branch.txt        # on the branch
diff /tmp/main.txt /tmp/branch.txt
```

Elapsed seconds and spinner frames differ between runs; anything else is a
regression. Two things noticed while building it, both present on `main`:

- A notice longer than the free header space overwrites the chips rather than
  truncating them.
- The fixture's fake `attach` reads a line, so a script that presses Enter on
  a row must follow it with a newline or every later key is swallowed.

## Status

| # | Recommendation | Status |
|---|---|---|
| 1 | Rules onto Row | PR #54 |
| 2 | Immutable Session, one loader | |
| 3 | One poller worker | |
| 4 | Tombstone instead of double publish | |
| 5 | Notices through the queue | |
| 6 | Dead peek message | |
| 7 | One line editor | |
| 8 | Named selection | |
| 9 | Renderer view struct | |
| 10 | Small things | |
