# Contributing

## Setup

```sh
bundle install
gh extension install basecamp/gh-signoff
```

`bin/ci` uses gh-signoff to mark your PR as passing, so install it before you
open one.

For tab completion of `gh signoff`, add `eval "$(gh signoff completion)"` to
`~/.zshrc`.

## Running from a checkout

`exe/claude-inbox` is what the gem installs. `bin/claude-inbox` loads it
through the checkout's Bundler, so it runs your working copy.

```sh
bin/claude-inbox                                        # live
bin/claude-inbox --fixture test/fixtures/agents.json    # no daemon needed
CLAUDE_INBOX_STDERR=/tmp/err.log bin/claude-inbox       # crash traces off the alt screen
DEBUG=1 bin/claude-inbox                                # slow-frame notes in /tmp/inbox-debug.log
CLAUDE_INBOX_NO_REAP=1 bin/claude-inbox                 # never delete an idle session
bin/claude-inbox --fixture test/fixtures/agents.json --listen=0   # the listener on a free port; N shows it,
                                                    # and the token is in $TMPDIR/claude-inbox-fixture/listen.json
bin/screens                                             # drive the fixture in a pty, print every screen
```

`--fixture` reads `agents.json`, `logs_raw.txt` and `jobs/` from the
directory of the file you pass, so a fixture can live anywhere.

To check a refactor against the real screen, run `bin/screens` on `main` and
on your branch and diff the two.

Read [docs/cli-quirks.md](docs/cli-quirks.md) before touching `lib/`. It
records what the daemon and CLI actually do, which `claude --help` doesn't.

The phone's page is `lib/claude_inbox/remote.html`, which the listener reads
once when the inbox starts, so restart after an edit. To try it, run the
fixture with `--listen=0`, press `N` and then `c`, and open the copied URL in
a browser; a phone-sized window and the dark scheme are a toggle away in its
developer tools. Starts go to the fixture, which starts nothing.

## Local CI and signoff

There's no hosted CI. `bin/ci` runs on your machine and reports back with
[gh-signoff](https://github.com/basecamp/gh-signoff). The suite takes about
four seconds.

1. Push your branch and open the PR.
2. Run `bin/ci`. It runs `bundle install`, `standardrb`, `bundle-audit` and
   `rake test`.
3. If every step passes and HEAD is on the remote, it runs `gh signoff`,
   which sets a green `signoff` status on the PR.
4. Merge.

With HEAD not pushed yet, `bin/ci` skips the signoff and says so, so it's
fine to run mid-work. Push, then run `gh signoff`. gh-signoff also refuses a
dirty working tree, since it can't vouch for commits that don't match what
you tested.

While iterating:

```sh
bundle exec rake test
bundle exec standardrb --fix
bundle exec bundle-audit check --update
gh signoff status        # is HEAD signed off?
```

## Cutting a release

You need push rights to the `claude-inbox` gem on rubygems.org (`gem signin`,
with your OTP at hand) and `gh` signed in to this repo. Then, on `main` with
a clean tree at `origin/main`:

```sh
bin/release --dry-run   # show the version it would release
bin/release
```

The version comes from the conventional-commit prefixes of the PRs merged
since the last tag. If none is a `feat` or `fix`, there's nothing to release.
