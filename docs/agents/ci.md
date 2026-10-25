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
  no run. The Forgejo CI bullet of the global CLAUDE.md lists every exit code.
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
  authority"). Before blaming the diff for a red test it does not touch, check whether
  `CI / test (push)` on `origin/main`'s head failed on the same test.
- **Flake.** A failure is a flake only when both hold: the failing test touches nothing in the
  diff, and the identical tree went green elsewhere (`git diff --stat <green sha> <red sha>`
  prints nothing). A red run never counts as green.
- **Wall-clock tests.** #637 (for #636) widened the subprocess bounds that raced process startup
  on the runner to 1 s. Two tight-bound tests still fail now and then on diffs that do not touch
  them: `Cinder.HTTPPolicyTest` "cancels a request blocked before headers at the wall-clock
  deadline" (a 100 ms deadline asserted under 300 ms), and
  `Cinder.Library.Filesystem.DiskBoundedTest` "run_rooted's sync_parent timeout is reported
  distinctly from a malformed helper, and the OS process is killed" (it got `{:error, :rooted_helper_timeout}` instead). Apply
  the flake rule before re-running.
- **Shared state.** Check order-dependent state before blaming a flake or a new test: the
  always-on `:login_pair` bucket of `Cinder.Accounts.IpRateLimiter`, keyed on the IP and the
  name (#686), and the suite-wide `Cinder.Subtitles.Fetcher` consuming another module's Mox
  expectations (#685). Give throttle tests unique names, and drain a shared worker with
  `:sys.get_state/1`.
- **CI runs the suite as root.** A test that makes a delete fail with `File.chmod` passes
  locally and fails on CI. Fail it at the `Cinder.Library.Filesystem` behaviour instead:
  `config/test.exs` already points `:filesystem` at `Cinder.Library.FilesystemMock`, so
  `stub_with(FilesystemMock, Cinder.Library.Filesystem.Disk)`, then
  `stub(FilesystemMock, :rm_rf, fn path -> {:error, :eacces, path} end)`.
- **Line cap.** `test/code_health_test.exs` fails any `lib/**/*.ex` file over `@max_lines`
  (1500) lines, counted with `String.split(content, "\n")`, one more than `wc -l`. Two PRs that
  each grow a file near the cap pass apart and break `main` together, so count the lines of every
  touched lib file on the merged tree before merging (`scripts/merge-pr` does).
- **Trivy DB outage.** A red `container` job whose "Download the Trivy vulnerability DB" step
  fails on both repositories (`ghcr.io`, then `mirror.gcr.io`; #835, #841) is an upstream outage,
  not the diff. Outages have lasted hours. Re-run once another run's `CI / container` went green
  after the outage began; one successful download from your own machine proves nothing about the
  runner.
- **New advisory.** `dependency-audit` and `container` go red on every PR once an advisory is
  published after `main`'s last green run, whatever the diff touches. Read the CVE lines in the
  job log: when they name dependencies or base-image packages the PR does not change, the
  failure is baseline and blocks every merge until a fix PR lands. `mix hex.audit` takes its
  accepted advisories from `ignore_advisories` in `mix.exs` (`hex/0`), each with a rationale
  comment. For Debian packages Trivy flags that a fresh `apt-get upgrade` fixes, set the
  Dockerfile's `APT_REFRESH` to today's date so the cached layer rebuilds. When fix PRs block
  each other, each red on an advisory another one fixes, carry them all on one branch: merge the
  others' branches into it, so it goes green alone. #885 carried #865 (`plug_crypto`, red on
  `container`) and #880 (`libbrotli1`, red on `dependency-audit`), and #865 also needed #885's
  own CI fix. Close each carried PR as superseded once the carrier merges; its `changelog.d/`
  fragment keeps its number. When `scripts/merge-pr --dry-run` prints `squash body from:` with a
  carried commit, pass `--body-from=<sha of the carrier's own fix commit>`.
- **Dependency rebuild.** A `mix.lock`, OTP or Elixir change misses the compiled-deps caches,
  so `test` and `dependency-audit` rebuild every dependency and download precompiled NIFs from
  GitHub releases. Erlang's `:httpc` refuses a response whose headers pass 10240 bytes (OTP 29),
  and GitHub's release redirect has passed that (#867), so a download can print
  `does not exist or cannot download: :enoent`. elixir_make then builds the NIF from source,
  lazy_html with the `cmake` that `test` installs on a miss, so that line alone is not the
  failure. The image build fetches Tailwind with `curl` for the same reason. To prove the NIF
  source-build fallback while the downloads work, put `config :elixir_make, :force_build,
  lazy_html: true, exqlite: true` in `config/test.exs` on a run whose compiled-deps cache
  misses, then revert it before the merge (#885's run 347). The `test` log shows the miss: the
  cmake install step runs only then. A green `test` job saves the cache under its exact key, so a
  later run with the same `mix.lock`, OTP and Elixir restores the NIFs and rebuilds nothing,
  flag or not.

## Re-running CI

- One PR: push an empty commit (`git commit --allow-empty -m "ci: re-run after <test> flake"`).
  A squash merge drops it.
- A PR in a stack: an empty commit forces every later PR to rebase and re-run, so re-run on the
  same SHA by closing and reopening the PR, which fires `pull_request: reopened`:
  `curl -s -X PATCH -H "Authorization: token $FJ_TOKEN" -H 'Content-Type: application/json' "$API/pulls/<n>" -d '{"state":"closed"}'`,
  wait about 20 s, then the same call with `{"state":"open"}`. Run both calls in one foreground
  step and check each response, or the PR can stay closed.
- Before you wait on the new run, confirm its statuses show `pending`, or the wait reads the old
  failure.

## Merge conflicts and translations

A branch syncs with `main` only on a conflict or a diff that touches `CHANGELOG.md` (AGENTS.md
"Merge authority"). For a conflict in `priv/gettext`, follow [workflow.md](workflow.md) "Merge
conflicts": `scripts/gettext-fill.exs` refills the French msgstrs from the side you did not take.
