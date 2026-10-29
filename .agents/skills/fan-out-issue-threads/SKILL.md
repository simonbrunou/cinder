---
name: fan-out-issue-threads
description: "Use when fanning out a queue of Forgejo issues to one T3 thread each, such as every `ready-for-agent` issue or a parent issue's children."
---

# Fan out issue threads

You are the orchestrator. Each issue gets its own top-level T3 thread that fixes it, reviews it,
merges it and runs a retro. You plan, launch, watch, verify and report, and the threads write the
code. The user reads your thread, not the children. For worker agents inside one session instead
of T3 threads, see the `direct-parallel-worker-agents` skill.

The **run record** of one issue is its thread id, PR, merge sha, main CI result, filed issues
and top retro items. Keep one per issue in a state file at
`/tmp/fan-out-<parent or thread id>/state.md`, so a context reset loses nothing.

## 1. Collect the queue

- List the issues ([issue-tracker.md](../../../docs/agents/issue-tracker.md)) and read each one's
  body, comments and dependencies. A decision comment on the issue is part of the spec. The list
  endpoint returns 50 issues a page, so read every page.
- Look for a stranded attempt of the same issue, such as a closed-unmerged PR or a finished
  thread whose branch never merged. Finish that branch instead of starting over (step 4).
- Read the CI state of `main` and of the open PRs in each repo. When they share one red check,
  handle it first ("Repo-wide red check" below).
- Audit cinder's `origin/main` lock too, since `main`'s statuses stay green after a new advisory
  ([ci.md](../../../docs/agents/ci.md) "New advisory"). Bandit advisories reached the queue that
  way on 2026-10-27 (#975) and 2026-10-29 (#999). It takes about 10 s:

  ```sh
  git -C ~/Projects/cinder fetch origin
  git -C ~/Projects/cinder worktree add --detach /tmp/cinder-audit origin/main
  nix develop /tmp/cinder-audit -c sh -c 'cd /tmp/cinder-audit && mix deps.get && mix hex.audit'
  git -C ~/Projects/cinder worktree remove /tmp/cinder-audit
  ```

  Exit 1 with a package under `Advisories:` is a repo-wide red check. `mix hex.audit` compiles
  nothing, so `mix deps.get` is all the seeding it needs. Use it over `mix deps.audit`, which
  still passed on Bandit's EEF-CVE-2026-116078 12 hours after OSV published it.

### Repo-wide red check

A new advisory or a CI break turns one check red on every PR of a repo, whatever the diff, and no
PR of that repo can merge until its fix lands. The run finds one in step 1, or a thread reports
one mid-run. Make the fix its own thread, launched first, even when its issue is not
`ready-for-agent` yet, and say so in the summary. While the fix runs, that repo's other threads
keep launching and working, and each holds its first push behind a gate. Their briefs get
`{{RED_CHECK}}`, naming the blocker and the gate (a `git show origin/main:<file>` check the thread
runs before its first push), and the threads already running get the same text as a message.
Message them all again when the fix merges. When the fix cannot merge, launch nothing more in
that repo, and tell its gated threads to push, open their PRs, report "not merged: blocked by
<fix>" and run their retros. On 2026-10-25 the plug_crypto advisory blocked cinder until #885
landed.

## 2. Plan lanes

- A lane is a sequence of issues that run one after another. Lanes run in parallel.
- Put issues in one lane when they edit the same files or one blocks the other, and order each
  lane by its blocking edges.
- Keep within the thread cap of the global CLAUDE.md's "T3 threads" section. The shared CI runner
  caps each repo further. Run at most two diversif threads, which take turns on E2E through
  diversif's `scripts/wait-e2e-slot.sh`, until homelab-stacks#254 gives E2E its own runner
  (diversif#478).

## 3. Write each brief

Fill [brief-template.md](brief-template.md) per issue, with the repo's values from its table. The
`{{HOW}}` block depends on the issue:

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
startFromOrigin: true}`. Record the thread id. Keep the word `rm` out of the slug, since the
permission check matches it inside a branch name.

To finish a stranded branch, use `{type: "existing_worktree", worktreePath, branch}` while its
worktree still exists, and otherwise `{type: "worktree", baseRef: "<stranded branch>", branch:
"<prefix>/<n>-<slug>-2", startFromOrigin: true}`. Fill the template, replace its first-commands
step 1 with `git fetch origin && git merge origin/main`, drop step 2 when the worktree is already
seeded, and add a paragraph on what is done and what remains.

## 5. Watch

Cycle `t3_thread_wait` over the running threads with 15-20 minute timeouts, and post a status
line each cycle. Each cycle also checks:

- **Your queue**, read and emptied as the global CLAUDE.md's "T3 threads" section says.
- **New PRs and their CI**, in every repo the run touches and in nix. Two open `retro/*` PRs
  that change the same file are twins. Tell the later thread to close its PR, or to fold what it
  adds into the earlier one (nix#55 and nix#59, cinder#909 and cinder#911).
- **CI overlap.** When two diversif runs queue together anyway, tell the later thread to cancel
  its run (`POST /actions/runs/<id>/cancel`) and rerun it once the other's E2E job ends.
  `GET /actions/runs` shows a queued run as `waiting`, and `GET /actions/tasks` leaves it out.
  When another repo's runs keep a thread's E2E over its time budget, tell every other thread to
  hold pushes and reruns until a stated time, the window the thread asked for. Such windows are
  needed until homelab-stacks#254 lands.
- **Stalls.** An `approval_request` item in a thread's `activity` view is a permission prompt
  nobody will answer, so `t3_thread_interrupt` the thread, then `t3_thread_send` it a resume
  message. `pendingRequestCount: 1` also shows during a plain long-running command, so it alone
  marks no stall. A thread idle for 10 minutes with work left, or settled with no REPORT block,
  gets a `t3_thread_send` nudge to finish in the foreground.

When a thread completes, read its REPORT block (step 6), then check Forgejo for the PR
`merged: true`, the issue closed and `origin/main` moved. Launch a lane's next issue only after
that check passes. A thread that stops without merging is a failure signal, so read why before
launching more.

When an outage or a rule change lands mid-run (a new `AGENTS.md` rule, a CI break), send every
running thread one message with the fact and the behaviour you expect, and add it to the brief
for later launches.

## 6. Report each run

Read the REPORT block with one call, `t3_thread_read` with `view: "messages"`, `limit: 6` and
`afterPosition` at the thread's `itemCount` minus 12. When it is missing, rebuild the record from
Forgejo and the thread's `activity` view, and count the miss in the summary. Post each finished
run's record in your own thread, with what changed in one or two sentences. When a retro item
recurs, add its fix to the brief for the remaining launches and say so.

## 7. Wrap up

- On the parent issue, if there is one, tick the checklist and list every `needs-triage` issue
  the run filed.
- For each retro item two or more threads reported, verify the claim on `origin/main` and file
  the repo-scoped ones as `needs-triage` issues. Name the rest (user-level config, other repos)
  in the final summary.
- Take every merge sha from the forge, since threads mix up merge and deploy shas. List each
  repo's PRs closed during the run with `GET /pulls?state=closed&sort=recentclose` and read
  `merged` and `merge_commit_sha`.
- List every PR an earlier run left open, with its CI state and the
  `git merge-tree --write-tree origin/main <head sha>` exit code, under what waits on the user.
- The final summary holds every run record, the behaviour changes a user can see, the recurring
  retro items with where each landed, and anything waiting on the user.
