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
  subprocess, writes under a library root, writes a movie, episode or book status, creates a
  request, or runs in the background.
- [Configuration](docs/agents/configuration.md): before adding a setting or env var, or touching
  secrets, `/settings`, the auth plugs or `/api/v1`.
- [Testing](docs/agents/testing.md): before writing a test or calling a task done.
- [Workflow](docs/agents/workflow.md): before starting a feature, an audit or a review, filing an
  issue, opening a PR, or cutting a release.
- [CI](docs/agents/ci.md): before reading a red CI run, re-running CI, or merging.
- [Subtitle sync](docs/agents/subtitle-sync.md): before changing `Cinder.Subtitles.Sync`, its
  engine or its timing rules.
- [Code navigation](docs/agents/code-navigation.md): before exploring `lib/` or `test/`, or
  inspecting the running dev app.
- [History](docs/agents/history.md): when you need the reason behind a past decision, or what is
  left on the roadmap.

## Changelog

A PR with a user-visible change adds one fragment, `changelog.d/<number>-<slug>.md`.
[changelog.d/README.md](changelog.d/README.md) says which PRs need one and how to write it.
`CHANGELOG.md` changes only in a release.

## Merge authority

Agents may merge their own PR without asking once all three hold:

- a code review ran on the diff (the `code-review` skill or the `pr-review-toolkit:code-reviewer`
  agent) and its real findings are fixed, nits aside (the global agent rules define a nit);
- CI is green on the PR's pushed SHA;
- the pushed SHA has no conflict with `origin/main`. Right before merging, run `git fetch origin`,
  then check that `git merge-tree --write-tree origin/main <pushed SHA>` exits 0.

The pushed SHA is the PR's head on Forgejo, which `git ls-remote origin refs/pull/<n>/head`
prints. It is the API's `head.sha` that `scripts/merge-pr` reads. A local checkout can hold
commits that were never pushed, or sit on `main` when you merge another thread's PR. Merge with
`scripts/merge-pr <n>`. It checks the last two conditions on the pushed SHA, the `CHANGELOG.md`
rule below and the `code_health_test` line cap on the merged tree, then merges pinned to that
SHA. It cannot check the review. A squash appends `(#<n>)` to the PR title, so it refuses a title
that already ends in another `(#N)`: name the issue in the squash body's `Closes #<issue>` instead.

A branch behind `main` with no conflict merges as it is, with no sync and no CI re-run. The
accepted risk is that two PRs that pass apart can break `main` together. The merging agent checks
for that break after the merge. A newer push to `main` cancels the `ci.yml` run in progress, so
in a burst of merges only the newest `main` commit's run is sure to finish. Run
`git fetch origin`, then wait on the `CI / <job> (push)` statuses of `origin/main`'s head with
`python3 -I ~/.agents/skills/forgejo-issues/scripts/forgejo.py ci cinder <sha>`
([ci.md](docs/agents/ci.md) "Reading a run"). That head is your merge commit or a newer one.
When the wait exits 1 on a job whose description reads `Has been cancelled`, fetch again. If
`origin/main` moved, a newer push cancelled that run, so wait on the new head. If it did not,
treat the run as red. When the newest run is red, search the open issues, since every agent that
merged in the burst sees the same run. Unless one already covers that run, file one labelled
`needs-triage` that names the failing job.

The merge-tree check exits 1 in two cases, told apart by their output. A conflict prints
`CONFLICT` lines on stdout. A SHA the clone lacks prints `<sha> - not something we can merge` on
stderr instead. In that case, run `git fetch origin refs/pull/<n>/head` or correct the SHA, and
check again. `scripts/merge-pr` fetches that ref and stops with `is not fetchable from origin`
when the SHA is still missing, so its merge-tree step exits 1 only on a conflict, which it
reports as `conflicts with origin/main`. On a conflict:

1. Merge `origin/main` into the branch and resolve the conflict.
2. Run `mix test`.
3. Push, wait for CI on the new pushed SHA, and check all three conditions again on it.

Do the same for a PR whose diff touches `CHANGELOG.md` even without a conflict, since a stale
entry under `[Unreleased]` merges cleanly and turns `main` red.

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
