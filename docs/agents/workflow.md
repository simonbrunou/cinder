# Workflow

## Scope

- One unit of work is one issue, fix or feature, on its own branch and PR.
- Audits and open-ended reviews deliver Forgejo issues, not inline fixes. Each fix then gets its
  own scoped session and PR.
- If a debugging loop repeats itself, stop, write down what you tried and what remains, and
  continue from a fresh context.

## Planning non-trivial work

Non-trivial work is planned on the issue tracker with Matt Pocock's skills before any code. A
small, obvious fix skips planning and goes straight to a branch and PR.

The planning skills are slash commands the user runs. When a non-trivial request arrives with no
spec issue behind it, suggest starting at step 1.

1. `/grill-with-docs` (or `/grilling` without the docs): interview until the design is settled.
   Resolved terms go to `GLOSSARY.md` and decisions to `docs/adr/`.
2. `/to-spec`: publish the spec as a Forgejo issue labelled `ready-for-agent`.
3. `/to-tickets`: split the spec into tracer-bullet tickets with blocking edges.
4. `/implement` for one ticket, or `/implement-spec` for a whole spec on an integration branch.
   Both build test-first with `tdd` and finish with `code-review`.

Work too large for one session starts with `/wayfinder` instead. Incoming issues go through
`/triage`. [issue-tracker.md](issue-tracker.md) maps what these skills do onto Forgejo.

## Branches and PRs

- PRs go to Forgejo (`origin`), not the GitHub mirror.
- Feature work goes on a branch and merges through a PR; `main` is PR-merged. Chores such as
  flake bumps may land directly, but a PR is the default.
- A queue of issues worked one T3 thread each follows the `fan-out-issue-threads` skill.

## Review

- Every review sub-agent's prompt gives the author's full `mix test` result line, to trust as it
  would green CI, and limits execution to a mutation check: revert the fix in the sub-agent's own
  worktree, seeded as "Worktrees" below says, and run only that test file. A reviewer told to
  check the author's claims checks them against that line and the diff, within the same
  one-file budget. A second full suite takes the CPU the host's agent threads share: on #959 a
  Spec reviewer re-ran the full suite in a copy of the worktree and took 12 minutes.

## Worktrees

- A fresh T3 worktree has no `deps/` or `_build/`. Run `scripts/seed-worktree` in it before any
  `mix` task: it copies the main checkout's `deps/` and `_build/test`, then runs `mix deps.get`.
  After a failure, run it again: it keeps what is complete. On a branch cut before the script
  existed, run `~/Projects/cinder/scripts/seed-worktree`. Its header says why it copies.
- If a test then behaves like old code, run `MIX_ENV=test mix compile --force`.
- The seed has only `_build/test`, and in the dev env a task recompiles every dependency first.
  `mix format`, `mix credo --strict` and `mix gettext.extract --merge` run in the test env by
  default (`cli/0` in `mix.exs`). Run any other standalone task as `MIX_ENV=test mix <task>`.

## Merge conflicts

- In `GLOSSARY.md`, keep every section from both sides.
- In a `.po` file, take either side, run `MIX_ENV=test mix gettext.extract --merge`, then refill
  the French msgstrs the other side had and clear any `#, fuzzy` flag the merge added.
  `scripts/gettext-fill.exs` does both from the other side's copy of each catalog
  (`default.po`, `errors.po`):
  `git show <other side>:priv/gettext/fr/LC_MESSAGES/default.po > /tmp/other-default.po`, then
  `MIX_ENV=test mix run --no-start scripts/gettext-fill.exs priv/gettext/fr/LC_MESSAGES/default.po /tmp/other-default.po`.
  It lists the entries still left to translate by hand.

## Releasing

Tag only when the user asks. Production deploys from `main` on every merge; a `v*` tag only
publishes the public GHCR image for other installs, and its workflow runs no tests. The fold
itself is in [CONTRIBUTING.md](../../CONTRIBUTING.md) "Releasing (maintainers)".

1. On a branch, bump `@version` in `mix.exs` and run `mix cinder.changelog.release`.
2. Open the PR. Its diff touches `CHANGELOG.md`, so merge `origin/main` into the branch, run
   `mix test`, push and wait for CI before it merges (AGENTS.md "Merge authority";
   `scripts/merge-pr` refuses otherwise). Once it merged, check that `changelog.d/` on `main`
   holds only `README.md`.
3. Tag the merge commit once Forgejo CI is green on it, meaning the three `CI / <job> (push)`
   statuses on that SHA are `success` ([ci.md](ci.md)):
   `git tag -a v<version> <sha> -m "Cinder <version>" && git push origin v<version>`. `origin`
   is Forgejo.
4. GitHub gets the tag through Forgejo's push mirror. Check with
   `git ls-remote --tags github v<version>`. If it is still missing after a minute, trigger the
   mirror with `curl -s -X POST -H "Authorization: token $FJ_TOKEN" "$API/push_mirrors-sync"`
   ([issue-tracker.md](issue-tracker.md) for the token). Then wait for `release.yml` on GitHub:
   `gh run list -R simonbrunou/cinder --workflow release.yml --limit 1` gives the run id, and
   `gh run watch <run id> -R simonbrunou/cinder --exit-status` waits for it. The multi-arch build
   takes about 20 minutes, longer than one 600 s Bash call, so run the watch again each time the
   call times out.
5. Check the registry, not the workflow's exit code: `scripts/verify-ghcr-release.sh <version>`.

- `latest` follows the most recently pushed tag, not the highest version (`release.yml`). To
  backfill several tags, push them oldest first, one at a time, each after the previous release
  run finished. Never push an older tag after a newer release.
- A tag is not a GitHub Release object. Create one only when the user asks.
