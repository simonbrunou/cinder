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
- Title the PR without a trailing `(#<n>)`, as the `ship-cinder-pr-on-forgejo` skill's "2. Open
  the PR" says, also when you copy a commit subject, and name the issue in the body's
  `Closes #<n>`. `scripts/merge-pr` stops on a title that ends in another `(#<n>)`, since the
  squash appends the PR's own number. That stop hit five threads on 2026-11-19 (#1497, #1470,
  #1488, #1456, #1476) and #1491's PR #1563 on 2026-11-20.

## Review

- Every review sub-agent's prompt gives the author's full `mix test` result lines (a partitioned
  run's summary lines and its closing `mix test: <n> of <n> partitions passed`, or a one-process
  run's `Result:` line), to trust as it would green CI. On a docs-only branch
  ([testing.md](testing.md)) it gives the fence run's `Result:` line instead and says CI runs the
  full suite on the PR's push. The prompt also limits execution to a mutation check: revert the
  fix in the sub-agent's own worktree, seeded as "Worktrees" below says, and run only that test
  file with `mix test.unchecked <file>` ([testing.md](testing.md)). A reviewer told to check the
  author's claims checks them against that line and the diff, within the same one-file budget. A
  second full suite takes the CPU the host's agent threads share: on #959 a Spec reviewer re-ran
  the full suite in a copy of the worktree and took 12 minutes.
- Paste the bullet above into each reviewer's brief before you start the reviewer. Briefs written
  from the `code-review` skill alone let reviewers run tests or a mutation in the author's
  checkout on #884, #960, #1004 and #939.
- Before you start the reviewers, run `git fetch origin`, then list the agent docs `main`
  changed after the branch's base:
  `git diff --name-only $(git merge-base HEAD origin/main) origin/main -- AGENTS.md docs/agents`.
  Each reviewer reads each listed file from the tree the PR merges into, since a checkout of the
  branch holds the base's copy. In your checkout of the branch, run
  `git merge-tree --write-tree origin/main HEAD`, and put the tree hash on its first line in each
  brief, with `git show <tree>:<path>` as the read. That tree keeps the branch's own edits too. A
  non-zero exit is a conflict: resolve it first as "Merge conflicts" below says. On #1718 the
  Standards review called a test comment's citation of a testing.md rule false, because that rule
  reached `main` after the branch's base.
- In a T3 thread, start each `delegate_task` reviewer at high effort in `target.options`
  (`reasoningEffort: "high"` for Codex, whose default model starts at `low`; `effort: "high"`
  for Claude), and with `isolation: "worktree"` when its brief allows the mutation check. The
  Codex reviewers on #1025 and #939 ran at `low` and ran no mutation check.
- Once you have read the report of a reviewer you started with the Agent tool's
  `isolation: "worktree"`, remove its worktree and branch, named by the `agentId:` line of the
  Agent result. Claude Code keeps the worktree once the reviewer checks out the reviewed commit,
  and it can leave the branch even when it removes the worktree. So run these steps from any
  checkout, whether or not the result prints `worktreePath:`. `<path>` is
  `~/Projects/cinder/.claude/worktrees/agent-<agentId>`.
  1. When `<path>` is gone, go to step 3. Otherwise this command must print at least one ref:
     `git -C ~/Projects/cinder for-each-ref --exclude='refs/heads/worktree-agent-*' --contains "$(git -C <path> rev-parse HEAD)"`.
     When it prints nothing, the worktree holds a commit that only it has. Keep the worktree and
     its branch, name them in your report, and stop here.
  2. Run `git -C ~/Projects/cinder worktree remove <path>`. When it exits 128, its message says
     which case you are in:
     - `cannot remove a locked working tree`: a live agent holds the lock. Keep the worktree and
       its branch, and stop here. `--force` refuses a locked worktree too.
     - `contains modified or untracked files`: the reviewer's throwaway mutation check left
       them. Read `git -C <path> status --short`, then run the command again with `--force`.
  3. Run `git -C ~/Projects/cinder branch -D worktree-agent-<agentId>`.

## Agent docs

- Load the `writing-for-agents` skill before the first draft of an edit to `AGENTS.md` or a
  `docs/agents/` file. Its description names only skills, `AGENTS.md` and `CLAUDE.md`, but its
  body covers any doc an agent reads. On #1011 (for #992) the first draft of `ci.md` restated
  one rule in three sections and ended a wait on a condition no status shows, against the
  skill's "Pruning" and "Steps and completion criteria". Three review fix rounds followed.
- Before you move a rule from agent memory or another outside source into the docs, search for
  it with `rg -n <term> docs lib`, and point to the place that already says it. On #828 the
  Standards review found the new profile-guard bullet repeating ADR 0004 item 5 and the health
  paragraph repeating the `Cinder.Health` moduledoc.
- When an edit lengthens a line of a bullet, rewrap the whole bullet: print it rewrapped with
  `sed -n '<first>,<last>p' <file> | fmt -c -w 100 | sed -E "s/([.?!][])\"']*)  /\1 /g"` (`fmt`
  puts two spaces after a sentence it joins across a line end, also one that ends in `)` or a
  quote) and paste that over the bullet with Edit. Then fix three things `fmt` does not see:
  a one-line bullet's new lines, which it leaves unindented, a line that starts with `- `,
  `* `, `+ ` or `1. `, which Markdown reads as a new item, and a code span split across two lines,
  which `test/code_health/agent_doc_line_length_test.exs` fails in `docs/agents`, `docs/adr`
  and `changelog.d`. On #1502 three hand rewraps each pushed the overflow onto the next line,
  past that fence's 100-character limit, and on #850 hand rewraps of comment blocks took about
  12 minutes.

## Tool claims

These bind a sentence in any doc, moduledoc, comment, test name or changelog fragment.

- A sentence about what Cinder's own code does holds for each case that code tells apart:
  each book kind or plan, each kind of configured value, each cap the path applies, and each
  guard that can skip a write on the way, such as a status re-read, an `if` on the reason or an
  insert that swallows its error. A comment on a wait holds for each order in which the tasks
  it waits on can finish, and for each state the handler that starts them branches on, such as
  a panel's first open and a reopen. Read the code for those cases before you write "every",
  "drops", "blocks" or "parks", and write "tries to" for a write a guard can skip. A test name
  says only what its body checks. On #803 (PR #1388) one review round found three such sentences:
  a moduledoc claim true for the e-book plan only, "every ISBN probe" where a search probes at
  most three, and a test name that promised a comparison its body never made. On #1491 (PR #1563)
  "has already held a book target or blocked a TV release" skipped the hold's status guard and
  `insert_quietly`, and each rewrite skipped another guard (`write_back_search/2`'s status
  re-read, the block's reason list): three review rounds, about 18 minutes from the first
  finding to the last fix. On #1581 (PR #1592) a test helper's comment described one finishing
  order of two chained fetches, and the panel's first open, as every case: a Standards finding,
  then a re-check residual, about 5 minutes from the first finding to the last fix.
- A test comment that says which wait, match or assertion ends the test names one case for each
  way the run can go wrong, and each claim comes from a run of that case. For a regression, the
  cases are the ways the code under test can break the behaviour: for a caller that kills a task
  at a deadline, a caller that waits past the deadline, one that returns without the kill, and a
  deadline that never fires. For a loaded runner, the cases are the places a stall or a lost
  signal can land: before the stub reports, after it, in the caller past its deadline, and a
  release that never arrives. A different assertion can catch each case. On #1511 (PR #1577) "a
  deadline that never cancels fails the match and the bound" held in no case: with the caller
  waiting past its deadline only the elapsed bound failed, since the task's own deadline check
  still returned `:request_timeout`, and with its kill removed only `refute Process.alive?/1`
  failed. A Standards review and two re-checks reworded it one case at a time, about 17 minutes
  from the first finding to the last re-check. On #1558 (PR #1580) the comments said a lost
  release ends on the caller's deadline and a hung request fails the result match. Suspended
  callers let the task's own elapsed check end the call, a caller stalled past the await exited
  `Task.await_many`, and a request stalled before its stub failed a 10 s `assert_receive`. A
  Standards review and a re-check found them one place at a time, about 10 minutes from the
  first finding to the last hunk check.
- A sentence that names a role several modules play, such as "the import" or "a search", holds
  for each module playing it and each input form it takes. Before you write it, list the modules
  with `rg` for the function the sentence names and its callers, and the input forms each caller's
  clauses tell apart, then name the narrower set or the exception in the sentence. On #1411
  (PR #1422) "the import reads a code as the grab froze it" was false for the standard import,
  which reads its episodes' current codes, and "a search reads a code through `resolve/4`" and its
  import twin were false for a scoped code. A Standards review and a re-check found them, about 15
  minutes from the first finding to the last fix.
- A sentence about what a tool prints or does (an abort line, a flag's effect, a retry) holds on
  every path in the tool's source that reaches it and for each input form that source tells apart
  (such as, for Swoosh's SMTP adapter, a text-only mail and a text+HTML mail), not only on the
  case its help text or your first run shows. Read that source first
  (`elixir -e 'IO.puts(:code.lib_dir(:mix))'` prints Mix's directory, its tasks under
  `lib/mix/tasks/`; an Elixir dependency's source is in `deps/<name>/lib`, an Erlang one's in
  `deps/<name>/src`), then prove each path and form with a run. On #1170 the first draft of
  `ci.md` "Test-file warning" repeated `mix help test` and missed two paths of Mix's
  `tasks/test.ex`. Two re-check rounds found them, 15 minutes from the first fix commit to the
  last. On #1555 (for #1548) a run with a text-only mail led to a fragment saying each `Headers:`
  line held the `To` address. With a text+HTML mail, 8 of 18 such lines held no `To`: a Standards
  finding, a fix commit and a re-check. For a library's API, the input forms include each option
  that sets the same limit, each variant of the call, and each flag or value that turns on the
  same mode. On #1518 (PR #1585) the first draft of the comment on the test Repo's `timeout` in
  `config/test.exs` named `timeout:` but not DBConnection's `deadline:`. It said the next Repo
  call raises, where `Repo.query/3` returns as `{:error, _}` what `Repo.query!/3` raises. It
  left out a transaction body that asks for a rollback, through `Repo.rollback/1` or a
  `Repo.transact/2` body's `{:error, _}`, and it named `--trace` but not `--slowest` or
  `--slowest-modules` above 0. A Standards review and two re-checks found them one round at a
  time: 11 minutes from the first finding to the last fix.
- For a tool outside the repo, such as mergerfs or coreutils `nice`, read its manual for every
  option and input that changes the claim, such as the niceness `nice -n` starts from, and link
  the manual for the conditions a feature needs instead of copying them. On #1336 (for #953) the
  first reviews found that mergerfs passthrough needs mergerfs running as root and that its
  `proxy-ioprio` option gives its threads the reader's I/O priority. The third re-check found
  that `nice -n 10` adds 10 to the caller's niceness: 31 minutes from the first finding to the
  last fix.
- A claim about what Prowlarr does, such as which queries it sends an indexer or which history
  entries it writes, holds for the Prowlarr version prod runs. Read that version's source before
  you write the claim. To print the version, send these lines on the stdin of
  `~/Projects/homelab-stacks/scripts/cinder-rpc`, which prints nothing the script returns:
  `{:ok, c} = Cinder.Indexers.ProwlarrApi.connection()`,
  `{:ok, s} = Cinder.Indexers.ProwlarrApi.get(c, "/api/v1/system/status")` and
  `IO.puts(s["version"])`. Then
  `git clone --depth 1 --branch v<version> https://github.com/Prowlarr/Prowlarr.git` into a
  `/var/tmp` folder fetches the source. On #1933 the triage asked how the version prod runs
  treats a TVDB search for an indexer whose caps lack `tvdbid`. That version was 3.1.0.5799, and
  `Fetch(TvSearchCriteria)` in its `src/NzbDrone.Core/Indexers/HttpIndexerBase.cs` answered it.
  Finding the version and its tag took the thread three calls.
- A sentence about an HTTP library's default timeout (Req, Finch, Mint) needs a run with
  `retry: false`: a connect timeout against a host that drops connection attempts, such as
  `192.0.2.1`, and a receive timeout against `Cinder.Test.SilentServer`. On #828 the first draft
  copied a "Mint ~30 s connect default" from agent memory. The run timed out at 5.0 s, Finch's
  `@default_connect_timeout 5_000`, and at 3.0 s with `connect_options: [timeout: 3_000]`.
- A change that narrows or renames what a feature covers (one book kind, one source) reaches
  each sentence a user reads about that feature. Search its user-facing words by their stem, not
  only the module name, in `lib/cinder_web`, `priv/gettext/default.pot` and `docs/`. Fix each
  sentence that now promises the wider scope, and read the HEEx for each control a doc names. On
  #813 (PR #1402) a search for the module name alone missed an adoption note and two docs that
  sent audiobook works to the e-book-only policy and named controls `/books/:id` does not have:
  three review rounds, about 16 minutes from the first finding to the last fix. There `monitor`
  also finds "Monitor an individual work's e-book or audiobook target", which "author policy"
  and "monitoring policy" miss.

## Worktrees

- A fresh T3 worktree has no `deps/` or `_build/`. Run `scripts/seed-worktree` in it before any
  `mix` task, and again after a failure; its header says what it does. On a branch cut before
  the script existed, run `~/Projects/cinder/scripts/seed-worktree`.
- `t3.json` keeps a fresh worktree free of `deps/`. Since 0.1.12, T3 Code can give a new worktree
  thread its own worktree of a Git repository it discovers in the project folder. T3 reads
  `t3.json` from the main checkout, and its `ignoreRepositories` entry `deps` keeps discovery out
  of `deps/`. Without it, T3 by default creates `deps/heroicons` in the new worktree, so the seed
  keeps that `deps/` and skips its copy, and `mix deps.get` replaces T3's worktree with a clone.
  Each later turn of the thread then fails with "Couldn't recreate thread workspace". Moving the
  clone out of the thread's folder lets T3 recreate its worktree and run the turn, until the next
  `mix deps.get` replaces it again.
- The seed also installs a runner for `.githooks/pre-push`, the format and Credo gates a push
  runs; the script's and the hook's headers say when each one skips.
- If a test then behaves like old code, run `MIX_ENV=test mix compile --force`.
- The seed has only `_build/test`, and in the dev env a task recompiles every dependency first.
  `mix format`, `mix credo --strict`, `mix gettext.extract --merge` and `mix test.unchecked` run
  in the test env by default (`cli/0` in `mix.exs`). Run any other standalone task as
  `MIX_ENV=test mix <task>`.

## Merge conflicts

- In `GLOSSARY.md`, keep every section from both sides.
- In a `.po` file, take either side, run `MIX_ENV=test mix gettext.extract --merge`, then run
  `scripts/gettext-fill.exs` on each catalog (`default.po`, `errors.po`) with the other side's
  copy of it, then translate by hand the entries it lists. Its header says which msgstrs it
  refills and gives the commands.

## Releasing

Tag only when the user asks. Production deploys from `main` on every merge; a `v*` tag only
publishes the public GHCR image for other installs, and its workflow runs no tests. The fold
itself is in [CONTRIBUTING.md](../../CONTRIBUTING.md) "Releasing (maintainers)".

1. On a branch, bump `@version` in `mix.exs` and run `mix cinder.changelog.release`.
2. Open the PR. Its diff touches `CHANGELOG.md`, so merge `origin/main` into the branch, run
   `mix test`, push and wait for CI before it merges (AGENTS.md "Merge authority";
   `scripts/merge-pr` refuses otherwise). Once it merged, check that `changelog.d/` on `main`
   holds only `README.md`.
3. Tag the merge commit itself once its own three `CI / <job> (push)` statuses are `success`.
   A green run on a later `main` commit tests a different tree, and the tag's workflow runs no
   tests. Wait with `forgejo.py ci cinder <sha>` ([ci.md](ci.md) "Reading a run"). Exit 0 means
   tag it: `git tag -a v<version> <sha> -m "Cinder <version>" && git push origin v<version>`.
   `origin` is Forgejo. On exit 1, run `git fetch origin`, then:
   - **Cancelled**: the exit 1 line says every failed context reads `Has been cancelled`, and
     `origin/main` points at a later commit ([ci.md](ci.md) "Re-running CI" says why that
     cancels the run). The line says to wait on the new head; for the tag, re-run instead. Wait
     until `origin/main`'s head run has finished, so the re-run cannot disturb the check its
     merging agent waits on:
     `forgejo.py ci cinder --follow main` exits 0 or 1. Then find the merge commit's `push` run
     and list its jobs ([ci.md](ci.md) "Re-running CI"). POST a rerun for each job whose
     `status` reads `cancelled`, whatever its `attempt`, and leave the `success` ones. Then wait
     on the SHA again as that section says. A merge that lands during the re-run cancels it too:
     start this bullet over.
   - **Red**: anything else, a cancelled run with `origin/main` still at the merge commit
     included. Judge it as [ci.md](ci.md) "Judging a red run" says.
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
