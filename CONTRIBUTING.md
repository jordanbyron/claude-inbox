# Contributing

## Setup

```sh
bundle install
gh extension install basecamp/gh-signoff
```

Optionally, for `gh signoff <tab>` completion, add to `~/.zshrc`:

```sh
eval "$(gh signoff completion)"
```

## Local CI and signoff

CI runs on your machine instead of GitHub Actions, following
[37signals' `gh-signoff`](https://github.com/basecamp/gh-signoff) approach — see
DHH's [_We're moving continuous integration back to developer
machines_](https://gist.github.com/dhh/c5051aae633ff91bc4ce30528e4f0b60). The
laptop is faster than a hosted runner and doesn't bill by the minute.

1. Push your branch and open the PR as usual.
2. Run `bin/ci`. It runs, in order:
   - `bundle install`
   - `standardrb` (rubocop, with the Standard ruleset)
   - `bundle-audit` (known CVEs in `Gemfile.lock`)
   - `rake test` (minitest/spec, `test/**/*_spec.rb`)
3. If every step passes **and** HEAD is already on the remote, `bin/ci` runs
   `gh signoff` for you, setting a green `signoff` commit status on the PR.
4. Merge.

If HEAD isn't pushed yet, `bin/ci` says so and skips the signoff rather than
failing — mid-work runs stay quiet. Push, then run `gh signoff` by hand.

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
GitHub won't merge a PR without it. Run it once per repo; it needs admin access.
