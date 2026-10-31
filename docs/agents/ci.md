# CI

## What runs

- `.forgejo/workflows/ci.yml` runs on the Forgejo runner for every PR and every push to `main`.
  It has three jobs, reported as commit statuses `CI / test`, `CI / container` and
  `CI / dependency-audit`, each suffixed `(pull_request)` or `(push)`. Branch protection on
  `main` requires `* (pull_request)`. GitHub runs no CI: its only workflow is `release.yml`, on a
  tag ([workflow.md](workflow.md) "Releasing").
- `test` runs the `mix test` alias with `MIX_ENV=test` and uploads its full output as the
  `mix-test-output` artifact, kept 14 days.
- `container` builds the image, boots it, runs the Playwright browser smoke
  (`.github/scripts/browser_smoke.py`, `browser_lifecycle.py`), then scans the image with Trivy
  (HIGH and CRITICAL, unfixed CVEs ignored).
- `dependency-audit` runs `mix hex.audit` and `mix deps.audit`.
- The runner is shared with other repositories, so a PR's jobs can queue behind their runs.

## Reading a run

Calls below use the token and `$API` from [issue-tracker.md](issue-tracker.md).

- Wait for CI on a pushed SHA with `forgejo.py ci cinder <sha>` (the shorthand from
  [issue-tracker.md](issue-tracker.md)) in one foreground Bash call with timeout 600000. Exit 3
  means still pending, so run it again. Exit 4 means no workflow ran for that commit: `ci.yml`
  runs on `pull_request` and on pushes to `main`, so a branch pushed before its PR exists gets
  no run. The `forgejo-issues` skill's "PRs and CI" section lists every exit code.
  `fj pr -R origin status <n> --wait` blocks until the whole run ends, which outlasts the Bash
  cap once the shared runner queues jobs, and fails while a commit has no check yet. For one
  SHA's raw statuses:
  `curl ... "$API/commits/<sha>/status" | jq '{state, statuses: [.statuses[] | {context, status}]}'`.
- Job logs: `curl ... -o logs.zip "$API/actions/runs/<run id>/logs"` returns a zip with
  one `<job>-<task id>-attempt-<n>.log` per job. Find the run id from the head SHA with
  `curl ... "$API/actions/runs?page=1&limit=10" | jq '[.workflow_runs[] | select(.commit_sha | startswith("<sha8>"))][0].id'`.
  Without `page`, `limit` is ignored and every run comes back. A status's `target_url`
  (`/actions/runs/<n>/jobs/<m>`) carries the run's index in the repo, not the id the logs
  endpoint needs.
- Grep a test log for `\d+\) test`, `Result:`, `FAIL:` and `FATAL`, then delete it.

## Judging a red run

- **Broken `main`.** Two PRs that pass apart can break `main` together (AGENTS.md "Merge
  authority"). A test that flakes under runner load also goes red on `main` now and then (#984),
  so a red on `origin/main`'s head does not show that your tree inherits a break. A red test
  that also failed on `origin/main`'s head and passes **Flake** step 1 first gets the PR's one
  re-run (**Flake** step 2). Nothing before the re-run tells the two cases apart. An open
  `CI flake:` issue that names the test misses a first sighting, and the logs zip of `main`'s run
  holds only the newest attempt of each job. A later green `main` run of a tree that still holds
  the test supports the flake reading, but does not replace the re-run. **Broken `main`** fits
  only when the PR's re-run fails again on the same test and `CI / test (push)` on
  `origin/main`'s head still fails on it. Read the head's status when you judge, not an older
  red, since a green re-run of `main`'s job or a newer push changes it. When it fits, find or
  file the issue for `main`'s red run as AGENTS.md "Merge authority" says. The wait ends when
  `CI / test (push)` on `origin/main`'s head passes that test, whether a fix landed, a later push
  ran green or `main`'s own re-run went green. A `success` status shows that. So does a red job
  whose log ("Reading a run") holds the suite's `Result:` line and no longer names the test among
  its failures. A red job with no `Result:` line does not prove the test passed, so keep waiting.
  Then merge `origin/main` into your branch and push ("Re-running CI").
- **Flake.** A failure is a flake only when both hold: the failing test touches nothing in the
  diff, and the identical tree went green on CI (`git diff --stat <green sha> <red sha>` prints
  nothing). A red run never counts as green. A fresh PR head has only its red run, so check the
  two conditions at different times:
  1. Before the re-run, check that the failing test touches nothing in the diff, and rule out
     three other causes of a red test: **Shared state**, **CI runs the suite as root** and
     **Line cap**. When the test touches the diff, the failure is the diff's to fix. When one of
     those three causes fits, handle it as that bullet says. Either way, the failure is not a
     flake, so skip the re-run. A red on `origin/main`'s head on the same test is no reason to
     skip it, since the re-run tells a flake from **Broken `main`**.
  2. Re-run the job once, as "Re-running CI" says. Only the re-run can supply the green run: a
     green re-run of the identical tree (the same SHA, or an empty commit on it) makes the
     failure a flake, even when `CI / test (push)` on `origin/main`'s head failed the same test.
     A re-run that fails again on the same test goes to **Broken `main`**, which says when that
     cause fits. A local `mix test` of that tree is not this green run (#916). It misses
     failures that happen only on CI (**CI runs the suite as root**). Its timing also says
     nothing about a wall-clock bound on the loaded runner.
- **Wall-clock tests.** #637 (for #636) widened the subprocess bounds that raced process startup
  on the runner to 1 s. `Cinder.HTTPPolicyTest` "cancels a request blocked before headers at the
  wall-clock deadline" runs a 500 ms deadline under a 1 s elapsed bound (#960), so neither a
  runner slow to bring the request task to its stub nor the 336 ms past the deadline seen on #908
  fails it. After a 3458 ms run on `main` (#984),
  `Cinder.Library.MediaInfo.FfprobeTest` "extract_subtitle/2 still times out when the process
  emits data faster than any poll tick" asserts the elapsed time under 5 s past its 1 s deadline
  instead of 2 s. After a 3060 ms run on `main` (#1022),
  `Cinder.Library.Filesystem.DiskBoundedTest` "run_rooted's sync_parent timeout is reported
  distinctly from a malformed helper, and the OS process is killed" asserts the elapsed time
  under 5 s past its 1 s bound instead of 2 s, since its window times two helper spawns and two
  kills. Both spawns run a `/bin/sh` stub found on `PATH` as `python3`, because Python's start
  missed the 1 s bound in each of them on the runner (#1024). The test environment widens
  `Cinder.Library.Filesystem.Disk`'s `:disk_subprocess_timeout_ms` to 20 s (#945), four times
  the production bound, to give a slow start on a loaded runner headroom. In a test that does not
  set its own bound, a Disk timeout such as `{:error, :rooted_helper_timeout}` therefore means
  the subprocess did not answer for 20 s: look for a hang, or a runner far more loaded than
  usual, before calling it a flake. One tight-bound test still fails now and then on diffs that
  do not touch it: `Cinder.LibrarySubtitlesTest` "folder movie import passes linked sidecars to
  the movies subtitle task", whose first `assert_receive :movie_scan` gave up after 5 s on a
  1060 s run, and a scan reached the mock only after the test had ended. #1007 leaves the cause
  open: the load, or the shared Fetcher that **Shared state** names. Judge such a failure as
  **Flake** says.
- **Shared state.** Check order-dependent state before blaming a flake or a new test: the
  always-on `:login_pair` bucket of `Cinder.Accounts.IpRateLimiter`, keyed on the IP and the
  name (#686), and the suite-wide `Cinder.Subtitles.Fetcher` consuming another module's Mox
  expectations (#685). Give throttle tests unique names, and drain a shared worker with
  `:sys.get_state/1`: the Fetcher through `Cinder.LibraryStubs.await_subtitle_tasks/0`
  ([testing.md](testing.md)).
- **CI runs the suite as root.** A test that makes a delete fail with `File.chmod` passes
  locally and fails on CI. Fail it at the `Cinder.Library.Filesystem` behaviour instead:
  `config/test.exs` already points `:filesystem` at `Cinder.Library.FilesystemMock`, so
  `stub_with(FilesystemMock, Cinder.Library.Filesystem.Disk)`, then
  `stub(FilesystemMock, :rm_rf, fn path -> {:error, :eacces, path} end)`.
- **Line cap.** `test/code_health_test.exs` fails any `lib/**/*.ex` file over `@max_lines`
  (1500) lines, counted with `String.split(content, "\n")`, one more than `wc -l`. Two PRs that
  each grow a file near the cap pass apart and break `main` together, so count the lines of every
  touched lib file on the merged tree before merging (`scripts/merge-pr` does). On a red, split
  the file as the test's failure message says.
- **Trivy DB outage.** A red `container` job whose "Download the Trivy vulnerability DB" step
  fails on both repositories (`ghcr.io`, then `mirror.gcr.io`; #835, #841) is an upstream outage,
  not the diff. Outages have lasted hours. Re-run once another run's `CI / container` went green
  after the outage began; one successful download from your own machine proves nothing about the
  runner.
- **New advisory.** `dependency-audit` and `container` go red on every PR once an advisory is
  published after `main`'s last green run, whatever the diff touches. Read the CVE lines in the
  job log: when they name dependencies or base-image packages the PR does not change, the
  failure is baseline and blocks every merge until a fix PR lands. For a Hex package, look for a
  fixed release first and bump to it: a red `deps.audit` prints `First patched versions:`
  (`NONE` when no release fixes it yet). A red `hex.audit` names none, but the advisory URL it
  prints does, and `mix hex.info <package>` lists the recent releases. The bump rebuilds every
  dependency (**Dependency rebuild** below). `mix hex.audit` takes its
  accepted advisories from `ignore_advisories` in `mix.exs` (`hex/0`), each with a rationale
  comment. For Debian packages Trivy flags that a fresh `apt-get upgrade` fixes, set the
  Dockerfile's `APT_REFRESH` to today's date so the cached layer rebuilds. When fix PRs block
  each other, each red on an advisory another one fixes, carry them all on one branch: merge the
  others' branches into it, so it goes green alone. #885 carried #865 (`plug_crypto`, red on
  `container`) and #880 (`libbrotli1`, red on `dependency-audit`), and #865 also needed #885's
  own CI fix. Close each carried PR as superseded once the carrier merges; its `changelog.d/`
  fragment keeps its number. When `scripts/merge-pr --dry-run` prints `squash body from:` with a
  carried commit, pass `--body-from=<sha of the carrier's own fix commit>`. Once the fix is on
  `main`, clear your own PR's red as "Re-running CI" says.
- **Dependency rebuild.** A `mix.lock`, OTP or Elixir change misses the compiled-deps caches,
  so `test` and `dependency-audit` rebuild every dependency and download precompiled NIFs from
  GitHub releases. The `container` job's image build redoes that work from its `mix deps.get`
  layer on when `mix.exs` or `mix.lock` change, from `mix deps.compile` on when
  `config/{config,prod}.exs` change, from the Tailwind download on when `TAILWIND_VERSION`
  changes, and from the start when the Dockerfile's `ELIXIR_VERSION`, `OTP_VERSION` or
  `DEBIAN_VERSION` change. Erlang's `:httpc` refuses a response whose headers
  pass 10240 bytes (OTP 29), and GitHub's release redirect has passed that (#867), so a download
  can print `does not exist or cannot download: :enoent`. elixir_make then builds the NIF from
  source, lazy_html with the `cmake` that `test` installs on a miss, so that line alone is not the
  failure. The image build fetches Tailwind with `curl` for the same reason. To prove the NIF
  source-build fallback while the downloads work, put `config :elixir_make, :force_build,
  lazy_html: true, exqlite: true` in `config/test.exs` on a run whose compiled-deps cache
  misses, then revert it before the merge (#885's run 347). The `test` log shows the miss: the
  cmake install step runs only then. A green `test` job saves the cache under its exact key, so a
  later run with the same `mix.lock`, OTP and Elixir restores the NIFs and rebuilds nothing,
  flag or not.

## Re-running CI

- A re-run tests the same SHA, and a PR job checks out the branch head, not a merge with
  `main`. So a re-run clears only a red the same tree can pass, such as a flake or an upstream
  outage. A red that a commit on `main` fixes, such as a new advisory, stays red (#974's run
  2494 after #975): merge `origin/main` into your branch and push instead. In a stack, merge
  it into the bottom PR's branch, then rebase the later ones. A red test that `origin/main`'s
  head also fails is the exception. Once it passes step 1 of **Flake** ("Judging a red run"), it
  gets the re-run first, and **Broken `main`** says when to merge `origin/main` instead.
- Re-run a red job on the same SHA through the API. The call names one job of one run and adds
  no commit, so it suits a PR, a PR in a stack and a `main` push run alike (#967's run 2410). On
  `main`, re-run only a job of `origin/main`'s head. Find the run id as "Reading a run" says,
  then list the run's jobs with
  `curl ... "$API/actions/runs/<run id>/jobs" | jq -c '.[] | {id, name, status, attempt}'`.
- A red job at `attempt` 1 gets the re-run. A red test gets it only when it passes both checks
  of step 1 of **Flake** ("Judging a red run"). The call is
  `curl -s -X POST -H "Authorization: token $FJ_TOKEN" "$API/actions/jobs/<job id>/rerun"`,
  which answers 204. A job at `attempt` above 1 was re-run already, by you or by another agent
  in a merge burst: wait on it while it reads `waiting` or `running`.
- When the POST answers anything but 204 on a PR, push an empty commit instead
  (`git commit --allow-empty -m "ci: re-run after <test> flake"`, which a squash merge drops). In
  a stack an empty commit forces every later PR to rebase and re-run, so close and reopen the PR
  instead, which fires `pull_request: reopened` on the same SHA:
  `curl -s -X PATCH -H "Authorization: token $FJ_TOKEN" -H 'Content-Type: application/json' "$API/pulls/<n>" -d '{"state":"closed"}'`,
  wait about 20 s, then the same call with `{"state":"open"}`. Run both calls in one foreground
  step and check each response, or the PR can stay closed. On `main`, which has no PR to reopen,
  a POST that fails leaves the run red.
- Before you wait on the re-run, confirm its statuses show `pending`, or the wait reads the old
  failure.
- When the re-run fails again, read its new log as "Judging a red run" says. On a PR, check a
  failure on the same test against **Broken `main`**. On `main`, a job that fails again leaves
  the run red (AGENTS.md "Merge authority").
- A newer push to the same ref cancels its run in progress, a re-run included (`ci.yml`'s
  `concurrency` group). On `main`, wait on the new head once one lands.

## Merge conflicts and translations

A branch syncs with `main` only on a conflict or a diff that touches `CHANGELOG.md` (AGENTS.md
"Merge authority"), or on a red that `main` clears ("Re-running CI", **Broken `main`**). For a
conflict in `priv/gettext`, follow [workflow.md](workflow.md) "Merge conflicts":
`scripts/gettext-fill.exs` refills the French msgstrs from the side you did not take.
