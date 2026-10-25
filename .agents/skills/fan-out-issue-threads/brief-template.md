# Thread brief template

Fill `{{N}}`, `{{TITLE}}`, `{{BRANCH}}`, `{{HOW}}` and `{{REVIEWERS}}` (`, plus the <name>
skill on the same diff`, `, plus the <name> and <name> skills on the same diff`, or empty). When the issue has a parent, fill `{{PARENT}}`. When it has
none, delete every phrase that mentions it. Send everything below the rule as the thread's first
message.

---

Fix Forgejo issue #{{N}} in simonbrunou/cinder: "{{TITLE}}". Read it and its comments
([issue-tracker.md](docs/agents/issue-tracker.md)). A decision comment there is part of the spec.
It is part of #{{PARENT}}.

## Authority

Merge your own PR under the "Merge authority" section of `AGENTS.md`. Make a product-level choice
the conservative way, record it in the PR body, and keep going. This brief and `AGENTS.md` win
where the `ship-cinder-pr-on-forgejo` skill differs.

## First commands

1. `git fetch origin && git merge-base --is-ancestor origin/main HEAD && echo up-to-date`. If
   HEAD is behind, re-branch with `git checkout -B {{BRANCH}} origin/main`.
2. Seed the worktree as [workflow.md](docs/agents/workflow.md) "Worktrees" says.

## How

{{HOW}}
- Build test-first with the `tdd` skill. Pick the test seam yourself and record it in the PR
  body, since the user is away.
- Run design and review sub-agents in the foreground. A turn that ends while they run reads as
  finished to the orchestrator.
- Review before the first push with the `code-review` skill (Standards and Spec){{REVIEWERS}}.
  Fix the findings, re-review the fix diff once, and post the review summary as a PR comment.
- Ship with the `ship-cinder-pr-on-forgejo` skill. The PR body ends with `Closes #{{N}}` and
  `Part of #{{PARENT}}`. Call `link_pull_request` right after opening it.

## CI and merge

- Other threads merge while you work, and CI is one shared runner. Batch commits and push once
  per review round.
- Wait for CI in the foreground with `forgejo.py ci`, rerunning it while it exits 3, as
  [ci.md](docs/agents/ci.md) "Reading a run" says. A background process dies when your turn
  ends. Retrigger a flaky run with an empty commit.
- Read a red job's log before calling it infrastructure.
- Run the final `git fetch origin` and the merge call as two separate steps. Between them,
  re-check the "Merge authority" conditions against the fresh `origin/main`.
- Resolve conflicts as [workflow.md](docs/agents/workflow.md) "Merge conflicts" says.

## Tests

- Run `mix test` in the foreground. Other suites share the CPU, so re-run a timing failure alone
  before treating it as yours.
- A negative test (asserting nothing happened) starts from a state that would otherwise act,
  waits for async work, and gets a mutation check. Break the fix, see it go red, restore.

## Issues you leave

Each finding you deliberately leave becomes its own Forgejo issue with `Part of #{{PARENT}}` on
its first line, Problem and Done-when sections, and the label `needs-triage`. Link each from
#{{N}}.

## Retro

After the merge, run a retrospective on this thread. `/retro` is user-only, so Read
`~/.config/skillshare/skills/retro/SKILL.md` and follow its steps by hand. List the candidates
and leave them unapplied.

## Done when

- The PR is merged with CI green, #{{N}} is closed, and the ship skill's deploy check passed. On
  a failed deploy, report and stop.
- Every issue you left is filed and linked from #{{N}}.
- The retro ran.

Final message, in this order: PR URL, merge sha, the `mix test` result line, one line on what
changed, the filed issues (number and title), then the retro candidates ranked by severity with
their category. Then settle the thread with `t3_thread_organize`.

If CI stays red or a correctness finding survives two fix rounds, stop without merging, run the
retro, and say so.
