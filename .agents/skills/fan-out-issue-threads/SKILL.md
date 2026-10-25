---
name: fan-out-issue-threads
description: "Use when fanning out a queue of Forgejo issues to one T3 thread each, such as every `ready-for-agent` issue or a parent issue's children."
---

# Fan out issue threads

You are the orchestrator. Each issue gets its own top-level T3 thread that fixes it, reviews it,
merges it and runs a retro. You plan, launch, watch, verify and report, and the threads write the
code. The user reads your thread, not the children. For worker agents inside one session instead
of T3 threads, see the `direct-parallel-worker-agents` skill.

The **run record** of one issue is its thread id, PR, merge sha, filed issues and top retro
items. Keep one per issue in a state file at `/tmp/fan-out-<parent or thread id>/state.md`, so a
context reset loses nothing.

## 1. Collect the queue

- List the issues ([issue-tracker.md](../../../docs/agents/issue-tracker.md)) and read each one's
  body, comments and dependencies. A decision comment on the issue is part of the spec.
- Look for a stranded attempt of the same issue, such as a closed-unmerged PR or a finished
  thread whose branch never merged. Finish that branch instead of starting over (step 4).

## 2. Plan lanes

- A lane is a sequence of issues that run one after another. Lanes run in parallel.
- Put issues in one lane when they edit the same files or one blocks the other, and order each
  lane by its blocking edges.
- Run at most three threads at once. The CI runner and the shared usage limit are the bottleneck,
  so more threads finish no sooner.

## 3. Write each brief

Fill [brief-template.md](brief-template.md) per issue. Its `{{HOW}}` block depends on the issue:

- For a refactor, the thread designs two interfaces with the `codebase-design` skill and posts
  the chosen one on the issue before coding. When the issue already proposes the interface, one
  written alternative replaces the design sub-agents. Both designs keep the issue's design
  preferences.
- For a question with a decision comment, the thread implements the decision as written.
- For a rename or a test-only change, name the proof, such as an empty `rg` for the old names or
  one replacement test per deleted test.

Each `{{HOW}}` copies any design preference the issue's body or a decision comment states (one
shared definition, a named seam) in the issue's words, since the Spec review checks the thread
against the issue (#781). It also names the lane's predecessor and what it changed, parallel
threads that touch nearby files, and paths in the issue that later merges moved. `{{REVIEWERS}}`
names each project reviewer the diff needs, from `approval-gate-reviewer` (approval gate, roles,
status writes), `release-parser-reviewer` (parsing, scoring, import) and `liveview-ui-reviewer`
(LiveView and HEEx).

## 4. Launch

Call `t3_thread_launch` with `title: "#<n> <short title>"`, the brief as `message`, and
`workspaceStrategy: {type: "worktree", baseRef: "main", branch: "<prefix>/<n>-<slug>",
startFromOrigin: true}`. Record the thread id.

To finish a stranded branch, use `{type: "existing_worktree", worktreePath, branch}` while its
worktree still exists, and otherwise `{type: "worktree", baseRef: "<stranded branch>", branch:
"<prefix>/<n>-<slug>-2", startFromOrigin: true}`. Fill the template, replace its first-commands
step 1 with `git fetch origin && git merge origin/main`, drop step 2 when the worktree is already
seeded, and add a paragraph on what is done and what remains.

## 5. Watch

- Cycle `t3_thread_wait` over the running threads with 15-20 minute timeouts, and post a status
  line each cycle.
- When a thread completes, read its final message, then check Forgejo for the PR `merged: true`,
  the issue closed and `origin/main` moved. Launch a lane's next issue only after that check
  passes. A thread that stops without merging is a failure signal, so read why before launching
  more.
- A thread that ends its turn waiting on a background watcher or agent may never wake. When one
  sits idle for 10 minutes with work left, `t3_thread_send` it a nudge to finish in the
  foreground.
- When an outage or a rule change lands mid-run (a new `AGENTS.md` rule, a CI break), send every
  running thread one message with the fact and the behaviour you expect, and add it to the brief
  for later launches.

## 6. Report each run

Post each finished run's record in your own thread, with what changed in one or two sentences.
When a retro item recurs, add its fix to the brief for the remaining launches and say so.

## 7. Wrap up

- On the parent issue, if there is one, tick the checklist and list every `needs-triage` issue
  the run filed.
- For each retro item two or more threads reported, verify the claim on `origin/main` and file
  the repo-scoped ones as `needs-triage` issues. Name the rest (user-level config, other repos)
  in the final summary.
- The final summary holds every run record, the behaviour changes a user can see, the recurring
  retro items with where each landed, and anything waiting on the user.
