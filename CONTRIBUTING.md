# Contributing

## Setup

```sh
bundle install
gh extension install basecamp/gh-signoff
```

If you want tab completion for `gh signoff`, add this to `~/.zshrc`:

```sh
eval "$(gh signoff completion)"
```

## Running from a checkout

The command lives in `exe/claude-inbox`, which is what the gem installs.
`bin/claude-inbox` sets up Bundler from the checkout and loads it, so it runs
your working copy:

```sh
bin/claude-inbox                                        # live
bin/claude-inbox --fixture test/fixtures/agents.json    # no daemon needed
```

`--fixture` reads `agents.json`, `logs_raw.txt` and `jobs/` from the directory
of the file you pass, so a fixture can live anywhere.

Other switches while developing:

```sh
CLAUDE_INBOX_STDERR=/tmp/err.log bin/claude-inbox   # crash traces off the alt screen
DEBUG=1 bin/claude-inbox                            # slow-frame notes in /tmp/inbox-debug.log
CLAUDE_INBOX_NO_REAP=1 bin/claude-inbox             # never delete an idle session
bin/claude-inbox --fixture test/fixtures/agents.json --listen=0   # the listener on a free port; N shows it
bin/screens                                         # drive the fixture in a pty, print every screen
```

`bin/screens` is how a refactor is checked against the real screen: run it on
`main` and on the branch and diff the two.

## Local CI and signoff

There is no GitHub Actions workflow. CI runs on your machine and reports back
with [gh-signoff](https://github.com/basecamp/gh-signoff), the 37signals setup
DHH describes in [_We're moving continuous integration back to developer
machines_](https://gist.github.com/dhh/c5051aae633ff91bc4ce30528e4f0b60). The
whole suite takes about four seconds here, which is less time than a hosted
runner needs to boot.

1. Push your branch and open the PR as usual.
2. Run `bin/ci`. It runs, in order:
   - `bundle install`
   - `standardrb` (rubocop, with the Standard ruleset)
   - `bundle-audit` (known CVEs in `Gemfile.lock`)
   - `rake test` (minitest/spec, `test/**/*_spec.rb`)
3. If every step passes and HEAD is already on the remote, `bin/ci` runs
   `gh signoff`, which sets a green `signoff` status on the PR.
4. Merge.

If HEAD isn't pushed yet, `bin/ci` skips the signoff and says so instead of
failing, so running it mid-work is fine. Push, then run `gh signoff` yourself.
A dirty working tree also blocks signoff; gh-signoff refuses to vouch for
commits that don't match what you tested.

Individual steps, while iterating:

```sh
bundle exec rake test
bundle exec standardrb --fix
bundle exec bundle-audit check --update
```

Useful commands:

| Command | What it does |
| --- | --- |
| `gh signoff` | Sign off on HEAD |
| `gh signoff --commit <sha>` | Sign off on a specific commit |
| `gh signoff status` | Show whether HEAD is signed off |
| `gh signoff -f` | Sign off despite unpushed or uncommitted changes |

### Making signoff a required check

`gh signoff install` adds `signoff` to `main`'s required status checks, so
GitHub won't merge a PR without it. Run it once per repo. It needs admin access.

## Cutting a release

You need push rights to the `claude-inbox` gem on rubygems.org (`gem signin`,
with your OTP at hand) and `gh` signed in to this repo. Then, on `main` with a
clean tree at `origin/main`:

```sh
bin/release --dry-run   # show the version it would release
bin/release
```

The version comes from the conventional-commit prefixes of the PRs merged since
the last tag; if none of them is a `feat` or `fix`, there is nothing to release.
