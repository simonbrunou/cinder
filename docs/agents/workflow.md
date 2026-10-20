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

## Worktrees

- A fresh T3 worktree has no `deps/` or `_build/`. Seed it with copies (a symlinked `_build`
  compiles one branch into another's tree), then fetch what the main checkout lacks:
  `cp -a ~/Projects/cinder/deps ./deps && mkdir -p _build && cp -a ~/Projects/cinder/_build/test _build/test && rm -rf _build/test/lib/cinder && mix deps.get`.
  If a test then behaves like old code, run `MIX_ENV=test mix compile --force`.
- The seed has only `_build/test`, so run standalone tasks in that env: `MIX_ENV=test mix format`,
  `MIX_ENV=test mix credo --strict`, `MIX_ENV=test mix gettext.extract --merge`. In the dev env
  they recompile every dependency.

## Merge conflicts

- In `GLOSSARY.md`, keep every section from both sides.
- In a `.po` file, take either side, run `MIX_ENV=test mix gettext.extract --merge`, then refill
  the French msgstrs the other side had and clear any `#, fuzzy` flag the merge added.
