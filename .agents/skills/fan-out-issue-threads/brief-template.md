# Thread brief template

Fill `{{REPO}}`, `{{N}}`, `{{TITLE}}`, `{{BRANCH}}`, `{{ORCHESTRATOR}}` (your own thread id) and
`{{HOW}}`, then the repo's values from the table. `{{REVIEWERS}}` is `, plus the <name> skill on
the same diff`, `, plus the <name> and <name> skills on the same diff`, or empty. When the issue
has a parent, fill `{{PARENT}}`; when it has none, delete every phrase that mentions it. While a
repo-wide red check is open (SKILL.md), fill `{{RED_CHECK}}` with the blocker and the push gate;
otherwise delete that section. Send everything below the rule as the thread's first message.

| Placeholder | cinder | diversif |
| --- | --- | --- |
| `{{DOCS}}` | the topic doc `AGENTS.md` names for the change | `docs/agents/testing.md` and `docs/agents/deploy.md` |
| `{{SETUP}}` | Seed the worktree as `docs/agents/workflow.md` "Worktrees" says | `nix develop -c bun install --frozen-lockfile` |
| `{{TEST}}` | `mix test` | `nix develop -c bun run test` |
| `{{SHIP}}` | Ship with the `ship-cinder-pr-on-forgejo` skill, and merge with `scripts/merge-pr <n>`. A user-visible change adds a `changelog.d/` fragment (AGENTS.md "Changelog"). | Open and merge the PR with `fj` as the global CLAUDE.md says, the body written with the `pr` skill. |
| `{{CI_RULES}}` | delete the bullet | Run `scripts/wait-e2e-slot.sh` before each push, merge to `main` or rerun, as `docs/agents/testing.md` says. |
| `{{DEPLOY}}` | the ship skill's deploy check | `scripts/smoke-prod.sh <new main sha>`, then read the CI run on the new `main` head as the Merge authority says |
| `{{REVIEWERS}}` | from SKILL.md step 3 | empty |

For another repo, take each value from its `AGENTS.md` and `docs/agents/`.

---

Fix Forgejo issue #{{N}} in simonbrunou/{{REPO}}: "{{TITLE}}". Read it and its comments
(`docs/agents/issue-tracker.md`). A decision comment there is part of the spec. It is part of
#{{PARENT}}. Orchestrator thread {{ORCHESTRATOR}} launched you, and no user reads this thread.

## Authority

Merge your own PR under the "Merge authority" section of `AGENTS.md`. Make a product-level choice
the conservative way, record it in the PR body, and keep going. This brief and `AGENTS.md` win
where a skill differs. On a design choice, the issue wins over this brief. If `origin/main`
already does what the issue asks, prove it (a test or a grep), post the evidence on the issue and
close it through the `forgejo-issues` skill, then go to the retro.

Read `AGENTS.md`, then {{DOCS}}, before you code.

## Unattended shell

Nobody answers a permission prompt here, so one stalls the thread for hours. Write every Bash
command for the global CLAUDE.md's bash parser, keeping the letters `rm` out of branch names and
paths in a compound command too. Put this paragraph at the top of every sub-agent prompt you
write.

## Repo-wide red check

{{RED_CHECK}}

## First commands

1. `git fetch origin && git merge-base --is-ancestor origin/main HEAD && echo up-to-date`. If
   HEAD is behind, re-branch with `git checkout -B {{BRANCH}} origin/main`.
2. {{SETUP}}.

## How

{{HOW}}
- Build test-first with the `tdd` skill. Pick the test seam yourself and record it in the PR
  body.
- Review before the first push with the `code-review` skill (Standards and Spec){{REVIEWERS}}.
  Fix the findings, re-review the fix diff once, and post the review summary as a PR comment.
- {{SHIP}} The PR body ends with `Closes #{{N}}` and `Part of #{{PARENT}}`. Call
  `link_pull_request` right after opening it.

## CI and merge

- {{CI_RULES}}
- Other threads merge while you work, and CI is one shared runner. Batch commits and push once
  per review round.
- Wait for CI in the foreground with `forgejo.py ci` (the `forgejo-issues` skill), running it
  again while it exits 3. A background process dies when your turn ends.
- Read a red job's log before rerunning it. When a check is red on code your diff does not touch,
  read what the repo's docs say about red runs, and tell the orchestrator when it looks
  repo-wide. Send to the orchestrator with `t3_thread_send` and mode `steer`, so the message
  reaches its running turn.
- When the orchestrator asks you to hold pushes and reruns until a stated time, hold them. When
  another repo's CI load keeps your job over its time budget, ask the orchestrator for such a
  window.
- Run the final `git fetch origin` and the merge as two separate steps. Between them, re-check
  every "Merge authority" condition against the fresh `origin/main`.
- Resolve conflicts as the repo's docs say.
- After the merge, check the deploy in a bounded foreground loop with {{DEPLOY}}. On a failed
  deploy, report and stop.

## Tests

- Run {{TEST}} in the foreground. Other suites share the CPU, so re-run a timing failure alone
  before treating it as yours.
- A negative test (asserting nothing happened) starts from a state that would otherwise act,
  waits for async work, and gets a mutation check. Break the fix, see it go red, restore.

## Issues you leave

Each finding you deliberately leave, and anything you found but did not fix, becomes its own
Forgejo issue (the `forgejo-issues` skill) with `Part of #{{PARENT}}` on its first line, Problem
and Done-when sections, and the label `needs-triage`. Search the open issues first so you file
no twin. Link each from #{{N}}.

## Retro

After the merge, or after you stop without merging, run a retrospective on this thread's own
session. `/retro` is user-only, so Read `~/.config/skillshare/skills/retro/SKILL.md` and follow
its steps by hand. No user reads this thread, so skip its "present to the user" step and apply
every candidate, one PR per fix.

- A fix goes in the repo that owns the file. {{REPO}} owns its `AGENTS.md`, `docs/agents/`,
  `CODING_STANDARDS.md`, skills, lint and CI. The nix flake (git.sbrn.eu/simonbrunou/nix) owns
  the global CLAUDE.md (`claude/CLAUDE.md`) and the global skills (`agents/skills/`).
- Work on nix in a worktree of its own, never on a branch of the shared `~/Projects/nix` clone.
  Run `git -C ~/Projects/nix fetch origin`, then
  `git -C ~/Projects/nix worktree add <tmpdir> -b retro/{{REPO}}-{{N}}-<slug> origin/main`, and
  `git -C ~/Projects/nix worktree remove <tmpdir>` after the merge.
- Other threads run retros at the same time, in the same files. Right before you open a fix PR,
  list the target repo's open PRs and read the diff of each `retro/*` PR that touches your file.
  When one already carries your fix, push onto it or skip yours.
- Run the `code-review` skill on each fix PR and fix its findings, then merge it under the target
  repo's Merge authority once CI is green, following the CI rules above. In nix, `just build`
  must also exit 0 in the worktree, and a PR on a path its Merge authority leaves to the user
  stays open for the report.
- After a nix merge on sbrn, roll it out in `~/Projects/nix` as nix's Merge authority says.
  Another thread may be rolling out there at the same time. When the clone is dirty or a step
  fails, leave the clone as it is and name the failure in the report, as that section says.

## Done when

- The PR is merged with CI green, #{{N}} is closed, and the deploy check passed. Or you stopped
  with a stated reason.
- Every issue you left is filed and linked from #{{N}}.
- The retro ran, and each of its fixes is merged or listed with the reason it stayed open.

If CI stays red on your diff or a correctness finding survives two fix rounds, stop without
merging, run the retro, and say so.

Your last text message is this block alone, filled in. Write it as a message, since the
orchestrator reads messages and never your reasoning.

```
REPORT {{REPO}}#{{N}}
PR: <url, or none>
Merge: <merge sha, or "not merged: <reason>">
Tests: <the test result line>
Change: <one line on what changed for the user or the code>
Deploy: <ok | failed: <what> | n/a>
Filed: <#n title; #n title | none>
Retro fixes:
- <repo>#<pr> <title>: merged <sha> | open: <reason> | skipped: <reason>
```

Then settle the thread with `t3_thread_organize` as the last call of that same turn, and end the
turn on that call, with no text after it.
