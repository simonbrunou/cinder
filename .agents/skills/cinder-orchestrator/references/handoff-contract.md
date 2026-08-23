# Cinder specialist handoff contract

This file is loaded by `cinder-orchestrator`. It standardizes what each specialist receives and returns so context does not depend on chat history.

## State root

```bash
STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/cinder-agent"
RUN_ID="$(date +%Y%m%d-%H%M)-<slug>"
RUN_DIR="$STATE_ROOT/$RUN_ID"
mkdir -p "$RUN_DIR"
```

Use absolute paths in handoffs. Never put credentials or `.env` contents in the run directory.

## Reconnaissance prompt — Claude Code, fresh/read-only

Write a prompt file containing:

```text
You are the architecture/reconnaissance specialist for Cinder.

USER INTENT
<verbatim request>

KNOWN CONSTRAINTS
<only constraints already established by the operator>

TASK
Investigate the CURRENT repository and explain what this change means architecturally. Do not edit files, create commits, or implement code.

Follow AGENTS.md exactly. For source questions under lib/ or test/, use Graphify first when graphify-out/graph.json exists. Use Tidewave when it is available and useful rather than guessing about the running app. Read relevant current specs/plans, but do not import ROADMAP.md unless historical rationale is needed.

Return:
1. Current architecture relevant to the request, with concrete files/modules.
2. Invariants and existing boundaries that the change must preserve.
3. What can be extended cleanly versus what should remain separate.
4. Material product decisions the operator must make. Ask only questions that change behavior/scope/integration/data ownership; resolve programming details from the repo yourself.
5. Risks, migrations, compatibility, recovery concerns.
6. A recommended minimal direction, including alternatives only where the tradeoff is real.

Do not propose speculative abstractions. Do not write code. Do not modify the repository.
```

Invoke:

```bash
bash .agents/skills/cinder-orchestrator/scripts/claude-readonly.sh \
  "$REPO" "$RUN_DIR/recon-prompt.md" \
  "$RUN_DIR/claude-recon.json" "$RUN_DIR/recon.md" \
  "$RUN_DIR/claude-recon-session.txt"
```

## Design/plan prompt — Claude Code, resume architecture session

After the operator has approved product decisions, create:

```text
Continue as Cinder's architecture/planning specialist. The following product decisions are authoritative for this run:

<approved decisions>

Using your reconnaissance plus the CURRENT repository, produce an implementation-ready design and plan. Do not modify the repository or implement code.

The design must include:
- goal and explicit non-goals;
- minimal architecture and integration boundaries;
- data model/migrations and compatibility if applicable;
- external-service behaviour boundaries if applicable;
- lifecycle/concurrency/crash-recovery implications if applicable;
- security/approval-gate implications if applicable;
- test strategy.

The plan must decompose work into focused PR-sized units. For each unit provide:
- goal;
- files/modules expected to change (approximate, not a command to overfit);
- acceptance criteria / "done when";
- targeted tests/checks;
- relevant repo-local reviewer skills;
- dependency on earlier units, if any.

Every unit ends with the repository's required verification, including full `mix test`; source-changing units also run `graphify update .` before completion.

Do not broaden scope. Surface any remaining decision instead of guessing.
```

Invoke the helper with the previous Claude session id as the sixth argument:

```bash
bash .agents/skills/cinder-orchestrator/scripts/claude-readonly.sh \
  "$REPO" "$RUN_DIR/design-plan-prompt.md" \
  "$RUN_DIR/claude-design.json" "$RUN_DIR/design-plan.md" \
  "$RUN_DIR/claude-recon-session.txt" \
  "$(cat "$RUN_DIR/claude-recon-session.txt")"
```

Split the returned Markdown into `design.md` and `plan.md` if useful; exact formatting is less important than preserving the approved content verbatim for Codex handoff.

## Implementation prompt — Codex, fresh per PR unit

```text
You are the implementation specialist for one bounded Cinder PR.

APPROVED DESIGN
<exact relevant approved design text>

THIS PLAN UNIT
<exact unit text and acceptance criteria>

OPERATOR DECISIONS
<approved decisions relevant to this unit>

BOUNDARIES
- Follow AGENTS.md and current repo-local instructions exactly.
- Implement only this approved unit. Do not redesign the feature or broaden scope.
- If the approved design conflicts with current repository reality in a material way, STOP and report the blocker; do not invent a replacement architecture.
- Tests must not hit real external services.
- Use Graphify/Tidewave as instructed by AGENTS.md when available.
- Write failing/regression tests first where appropriate, then implement.
- Make focused commits as the plan warrants.
- Do not push, open a PR, merge, or alter unrelated code.
- Do not weaken tests/lint/formatting to get green.

DONE WHEN
- this unit's acceptance criteria are met;
- relevant focused checks pass;
- full `mix test` passes;
- `graphify update .` has run after source changes;
- the worktree contains committed, focused changes ready for independent review.

At the end, summarize commits, tests run, and any residual risk. If blocked, state the smallest decision needed.
```

Invoke:

```bash
bash .agents/skills/cinder-orchestrator/scripts/codex-implement.sh \
  "$WORKTREE" "$RUN_DIR/codex-prompt.md" \
  "$RUN_DIR/codex-events.jsonl" "$RUN_DIR/codex-last.md" \
  "$RUN_DIR/codex-thread.txt"
```

## Review prompt — Claude Code, always fresh/read-only

Never resume the architecture session for review.

```text
You are the independent reviewer for a Cinder implementation PR. Read only; do not edit files or create commits.

APPROVED DESIGN / PLAN UNIT
<approved text>

TASK
Review the complete diff from its merge-base with the intended base branch. Validate it against current AGENTS.md, the approved design/plan, surrounding implementation and tests.

Read and apply any relevant reviewer contracts under `.agents/skills/*/SKILL.md`. In particular:
- approval/request/role changes: approval-gate-reviewer;
- LiveView/HEEx/components: liveview-ui-reviewer;
- release parsing/matching: release-parser-reviewer;
- dependency/version changes: the dependency/version checker skills.

Look for high-confidence correctness, architecture, lifecycle/concurrency, security/authorization, regression, insufficient-test, UI/accessibility, and scope-drift issues. Do not nitpick style already enforced by tooling. Do not praise correct code.

For each finding output:
[severity] file:line — short title
Broken: concrete consequence/invariant violation.
Fix: concrete expected correction.

If clean, output exactly:
No high-confidence regressions or approved-design violations found in the reviewed diff.
```

Invoke with a new Claude session (no resume argument):

```bash
bash .agents/skills/cinder-orchestrator/scripts/claude-readonly.sh \
  "$WORKTREE" "$RUN_DIR/review-prompt.md" \
  "$RUN_DIR/claude-review.json" "$RUN_DIR/review.md" \
  "$RUN_DIR/claude-review-session.txt"
```

## Fix prompt — resume the same Codex implementation thread

```text
Continue the SAME approved Cinder plan unit. Independent review/CI found the issues below:

<FINDINGS>

Fix only these defects and any directly required regression coverage. The approved design, scope, and AGENTS.md constraints remain unchanged. Do not redesign or broaden the unit.

Run targeted checks, then full `mix test`, and `graphify update .` after source changes. Commit the fixes. Do not push or merge.
```

Run `codex-implement.sh` again; because `codex-thread.txt` exists, the helper resumes the exact thread and verifies that the returned `thread_id` matches.

## Operator handoff template

Keep it short:

```text
PR <n>: <title>
Plan unit: <unit>
Changes: <2-4 lines>
Verification: <targeted checks>; mix test <status>; CI <status>
Independent review: clean | <n findings fixed>
Remaining risk/decision: none | <brief item>
Ready for your merge decision.
```
