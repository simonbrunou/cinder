# Cinder

Cinder is a single-household, self-hosted Phoenix/LiveView app on SQLite that replaces the
Sonarr/Radarr/Seerr loop and Readarr/Bookshelf: request a movie, TV series, e-book or audiobook,
and Cinder finds, downloads and imports the best release into Jellyfin/Plex, Booklore or
Audiobookshelf.

## Commands

- `mix test` is the only green gate, locally and in CI. The alias runs
  `compile --warnings-as-errors`, `format --check-formatted`, `credo --strict`, then the suite.
- Mix and Hex manage dependencies. The Elixir/OTP toolchain comes from the Nix flake dev shell;
  if `mix` is not on `PATH`, run `nix develop --command mix test`.

## Topic docs

Read the matching doc before you act:

- [Architecture](docs/agents/architecture.md): before code that calls an external service or a
  subprocess, writes a movie, episode or book status, creates a request, or runs in the
  background.
- [Configuration](docs/agents/configuration.md): before adding a setting or env var, or touching
  secrets, `/settings`, the auth plugs or `/api/v1`.
- [Testing](docs/agents/testing.md): before writing a test or calling a task done.
- [Workflow](docs/agents/workflow.md): before starting a feature, an audit or a review, filing an
  issue, or opening a PR.
- [Code navigation](docs/agents/code-navigation.md): before exploring `lib/` or `test/`, or
  inspecting the running dev app.
- [History](docs/agents/history.md): when you need the reason behind a past decision, or what is
  left on the roadmap.

## Changelog

A PR with a user-visible change adds one fragment, `changelog.d/<number>-<slug>.md`, in the
format of [changelog.d/README.md](changelog.d/README.md). `CHANGELOG.md` changes only in a release.

## Merge authority

Agents may merge their own PR without asking once all three hold:

- a code review ran on the diff (the `code-review` skill or the `pr-review-toolkit:code-reviewer`
  agent) and its real findings are fixed;
- CI is green on the pushed SHA;
- the branch has no conflict with `origin/main`: after `git fetch origin`,
  `git merge-tree --write-tree origin/main HEAD` exits 0.

A branch behind `main` with no conflict merges as it is, with no sync and no CI re-run. Accepted
risk: two PRs that pass apart can break `main` together, and the next PR's CI shows it. On a
conflict, merge `origin/main` into the branch, resolve it, run `mix test`, push, and wait for CI
on the new head. Do the same for a PR whose diff touches `CHANGELOG.md` even without a conflict:
a stale entry under `[Unreleased]` merges cleanly and turns `main` red.

The production deploy that the merge triggers is accepted. Ask first only when the PR drops or
rewrites stored data (a destructive migration, a backfill that overwrites rows).

## Agent skills

### Issue tracker

Forgejo issues on git.sbrn.eu/simonbrunou/cinder, through `fj` and the Forgejo API. See
[issue-tracker.md](docs/agents/issue-tracker.md).

### Triage labels

The five default roles: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`,
`wontfix`. See [triage-labels.md](docs/agents/triage-labels.md).

### Domain docs

Single-context: `GLOSSARY.md` and `docs/adr/` at the repo root, created when first needed. See
[domain.md](docs/agents/domain.md).

<!-- Dependency usage rules below are managed by:
     mix usage_rules.sync AGENTS.md --all --link-to-folder deps --remove-missing
     Do not hand-edit inside the markers; put custom guidance above. -->

<!-- usage-rules-start -->
<!-- usage-rules-header -->
# Usage Rules

**IMPORTANT**: Consult these usage rules early and often when working with the packages listed below.
Before attempting to use any of these packages or to discover if you should use them, review their
usage rules to understand the correct patterns, conventions, and best practices.
<!-- usage-rules-header-end -->

<!-- usage_rules-start -->
## usage_rules usage
_A dev tool for Elixir projects to gather LLM usage rules from dependencies_

[usage_rules usage rules](deps/usage_rules/usage-rules.md)
<!-- usage_rules-end -->
<!-- usage_rules:elixir-start -->
## usage_rules:elixir usage
[usage_rules:elixir usage rules](deps/usage_rules/usage-rules/elixir.md)
<!-- usage_rules:elixir-end -->
<!-- usage_rules:otp-start -->
## usage_rules:otp usage
[usage_rules:otp usage rules](deps/usage_rules/usage-rules/otp.md)
<!-- usage_rules:otp-end -->
<!-- phoenix:ecto-start -->
## phoenix:ecto usage
[phoenix:ecto usage rules](deps/phoenix/usage-rules/ecto.md)
<!-- phoenix:ecto-end -->
<!-- phoenix:elixir-start -->
## phoenix:elixir usage
[phoenix:elixir usage rules](deps/phoenix/usage-rules/elixir.md)
<!-- phoenix:elixir-end -->
<!-- phoenix:html-start -->
## phoenix:html usage
[phoenix:html usage rules](deps/phoenix/usage-rules/html.md)
<!-- phoenix:html-end -->
<!-- phoenix:liveview-start -->
## phoenix:liveview usage
[phoenix:liveview usage rules](deps/phoenix/usage-rules/liveview.md)
<!-- phoenix:liveview-end -->
<!-- phoenix:phoenix-start -->
## phoenix:phoenix usage
[phoenix:phoenix usage rules](deps/phoenix/usage-rules/phoenix.md)
<!-- phoenix:phoenix-end -->
<!-- usage-rules-end -->
