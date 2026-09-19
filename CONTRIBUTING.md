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

Releases are cut from your machine too, by `bin/release`, once the PRs you want
in it are merged. Run it on `main` with a clean tree at `origin/main`:

```sh
bin/release --dry-run   # say what would be released, change nothing
bin/release
```

It reads the commits since the last `v*` tag (squash merges, so each is a PR
title) and picks the bump from their conventional-commit prefixes: a `!` or a
`BREAKING CHANGE:` footer bumps major, `feat` bumps minor, `fix` bumps patch,
and anything else (`docs`, `refactor`, `chore`) releases nothing. While the
version is still 0.x a breaking change bumps minor, per semver. The first
release, with no tag yet, ships `VERSION` as it stands.

Then it rewrites `VERSION` in `lib/claude_inbox.rb`, commits
`chore: release vX.Y.Z`, tags, builds and pushes the gem (rubygems asks for
your OTP here; that prompt is expected), pushes `main` with the tag and opens
a GitHub release with generated notes. If the gem build or push fails, the
commit and tag are undone so nothing half-released is left behind.
