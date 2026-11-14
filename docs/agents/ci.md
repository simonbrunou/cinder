# CI

## What runs

- `.forgejo/workflows/ci.yml` runs on the Forgejo runner for every PR and every push to `main`.
  It has three jobs, reported as commit statuses `CI / test`, `CI / container` and
  `CI / dependency-audit`, each suffixed `(pull_request)` or `(push)`. Branch protection on
  `main` requires `* (pull_request)`. GitHub runs no CI: its only workflow is `release.yml`, on a
  tag ([workflow.md](workflow.md) "Releasing").
- `test` runs the `mix test` alias with `MIX_ENV=test` and uploads its full output as the
  `mix-test-output` artifact, kept 14 days.
- `container` builds the image, boots it, runs `Disk.exchange/2`'s `mv --exchange` fallback in
  the running node (`.github/scripts/mv_exchange_check.exs`, the only CI run of a real
  `mv --exchange`: the `test` job's coreutils lacks it), runs the Playwright browser smoke
  (`.github/scripts/browser_smoke.py`, `browser_lifecycle.py`), then scans the image with Trivy
  (HIGH and CRITICAL, unfixed CVEs and the CVEs listed in `.trivyignore` ignored).
- `dependency-audit` runs `mix hex.audit` and `mix deps.audit`.
- The runner is shared with other repositories, so a PR's jobs can queue behind their runs.

## Browser scripts locally

To run `browser_smoke.py` and `browser_lifecycle.py` before CI does, as a fix or a test of client
JS needs, follow the `container` job on the host with these changes:

1. Export the `CINDER_SMOKE_*` values of the job's "Browser smoke" step, with
   `CINDER_SMOKE_BASE_URL=http://127.0.0.1:<port>` for a free `<port>`, and
   `CINDER_SMOKE_CONTAINER=<name>`. The boot below reads `CINDER_SMOKE_BOOTSTRAP_TOKEN`. Leave
   `CINDER_SMOKE_BROWSER_CHANNEL` unset: CI runs Playwright's bundled Chromium (#842).
2. `docker build -t cinder:<tag> .`
3. `docker rm --force <name>`, since the job boots a fresh container for each run. Then run the
   "Boot a fresh instance" step's `docker run` with `--name <name>`, image `cinder:<tag>`, and
   `-p 127.0.0.1:<port>:4000` in place of `--network "container:$(hostname)"`, which joins the
   job container's network. Wait for `curl -fs http://127.0.0.1:<port>/healthz` as the step does
   (30 tries, 1 s apart), then run its `mark_setup_complete` eval through `docker exec <name>`.
4. Build the venv on `/usr/bin/python3` and install the Playwright version the job pins; skip the
   job's `playwright install-deps`, which installs apt packages. A venv on the nix `python3`
   fails to import Playwright's `greenlet` with `libstdc++.so.6: cannot open shared object file`
   (#702; nix#79 logged it on 2026-10-31). Playwright uses the browsers already in
   `~/.cache/ms-playwright`; run `<venv>/bin/playwright install chromium` when that folder lacks
   the build the pinned version expects.
5. Run `<venv>/bin/python .github/scripts/browser_smoke.py`, then `browser_lifecycle.py` the same
   way: the smoke registers the account the lifecycle cases log in with. The run passed when both
   exit 0, and the lifecycle script then prints `All <n> lifecycle cases passed.` With
   `CINDER_SMOKE_SCREENSHOT_DIR` set, the lifecycle script saves a full-page screenshot of each
   failed case; `docker logs <name>` shows the server's side.

A one-off script built on `browser_lifecycle.py` that measures what a viewer sees after a live
patch, such as a poster that moves to another card or one already in the browser's cache,
leaves out the `page.route` that `main()` sets on `**/image.tmdb.org/**`. Playwright turns off
the browser's HTTP cache while a route is set (`Page.route`'s docs: "Enabling routing disables
http cache"), so each moved poster is fetched again and the measurement counts those fetches.
Seed posters the browser can cache instead, such as real TMDB poster paths, which answer
`cache-control: public, max-age=31919000`. On #1234 every moved poster on the keyed grid dipped
below opacity 1 in 8 of 8 routed trials and in none once the route was gone: about 35 minutes
from the first routed run to the rerun without it.

## Changing a workflow

- A `run:` step with logic of its own (a guard, a loop, a branch on a value) that you add, or
  whose logic you change, gets a test under `test/code_health/` that runs the step's text from
  the YAML under the runner's shell flags, as `test/code_health/ci_container_attempt_test.exs`
  does (its `@bash_flags`). The test puts a stub first on `PATH` for each external command whose
  result the step acts on, and fails each of those calls in turn. On #1223 the step's red runs
  lived in a scratch harness until the Standards review, about 20 minutes from that finding to the
  pushed test. That test's stub then failed every call, which stopped the removal step at its
  first `docker ps`, and the re-check found three later `docker` calls whose failure no test
  reached.

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
  `curl ... "$API/actions/runs?head_sha=<full sha>" | jq '[.workflow_runs[] | select(.event == "<push or pull_request>")][0].id'`.
  Pass the full 40-character SHA, which `git rev-parse <sha>` prints. A short one matches no run
  and prints `null`. One SHA can carry both a `push` and a `pull_request` run, so name the event
  you want in the `select`. Forgejo files the run of a push to an open PR as `pull_request_sync`
  while its `event` field reads `pull_request`, so the `select` finds it and the URL's
  `&event=pull_request` filter would not. A PR closed and reopened on the same SHA leaves several
  runs of one event. The API lists runs newest first, so `[0]` is the newest. A status's
  `target_url` (`/actions/runs/<n>/jobs/<m>`) carries the run's index in the repo, not the id the
  logs endpoint needs.
- Grep a test log for `\d+\) test`, `Result:`, `FAIL:`, `FATAL`, `ERROR! Test suite aborted` and
  `warning:`, then delete it.

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
     flake, so skip the re-run.
     - On a PR, the diff is the PR's own. A red on `origin/main`'s head on the same test is no
       reason to skip the re-run, since the re-run tells a flake from **Broken `main`**.
     - On a red test of `origin/main`'s head, the head's run can be the first one to test several
       merges ("Re-running CI"), so the diff is `git diff --name-only <last green sha> <head sha>`.
       The last green sha is the first commit that `git rev-list --first-parent <head sha>^`
       lists whose `CI / test (push)` status reads `success` (`$API/commits/<sha>/status`,
       "Reading a run"). Only that context decides: a commit whose `container` or
       `dependency-audit` job failed is the last green when its `test` passed, and a `failure`
       that reads `Has been cancelled` is not green. A skipped re-run leaves the run red for the
       search and the issue that AGENTS.md "Merge authority" asks for.
  2. Re-run the job once, as "Re-running CI" says. Only the re-run can supply the green run: a
     green re-run of the identical tree (the same SHA, or an empty commit on it) makes the
     failure a flake, even when `CI / test (push)` on `origin/main`'s head failed the same test.
     A re-run that fails again on the same test goes to **Broken `main`**, which says when that
     cause fits. A local `mix test` of that tree is not this green run (#916). It misses
     failures that happen only on CI (**CI runs the suite as root**). Its timing also says
     nothing about a wall-clock bound on the loaded runner.
- **Wall-clock tests.** #637 (for #636) widened the subprocess bounds that raced process startup
  on the runner to 1 s. `Cinder.HTTPPolicyTest` "cancels a request blocked before headers at the
  wall-clock deadline" runs a 500 ms deadline. The test takes the request task's pid from
  `bounded_request/3`'s `[:cinder, :http, :request_task]` event. It asserts that task dead and
  accepts a missing `{:request_started, _}` from the stub. A runner slower than the deadline to
  bring the task to its stub therefore passes the test. Before this, a 100 ms deadline (#960) and then
  a 500 ms one (#1092) each failed on such a runner, since a wider deadline only moves the start
  time that fails. After run 1082 (#1301) timed out a 500 ms deadline, "collects a trickling
  response that completes within the total deadline" runs a 10 s one. Widening holds there: its
  deadline must not fire and the call ends in about 6 ms, so only a 10 s stall on the runner times
  it out, where a wider cancel deadline still fails at a later start. After loaded runners
  returned 336 ms (#908), then 875 ms (#1038) past the deadline, the first cancel test asserts
  the elapsed time under 5 s past it instead of 1 s, and its stub's safety valve sits at 10 s,
  above that bound. "cancels a request whose task reaches the stub only after the deadline" holds
  its task 10 s in a Req request step and asserts the same bound. After a 3458 ms run on `main`
  (#984),
  `Cinder.Library.MediaInfo.FfprobeTest` "extract_subtitle/2 still times out when the process
  emits data faster than any poll tick" asserts the elapsed time under 5 s past its 1 s deadline
  instead of 2 s. After a 3060 ms run on `main` (#1022),
  `Cinder.Library.Filesystem.DiskBoundedTest` "run_rooted's sync_parent timeout is reported
  distinctly from a malformed helper, and the OS process is killed" asserts the elapsed time
  under 5 s past its 1 s bound instead of 2 s, since its window times two helper spawns and two
  kills. Both spawns run a `/bin/sh` stub found on `PATH` as `python3`, because Python's start
  missed the 1 s bound in each of them on the runner (#1024).
  `Cinder.Subtitles.Sync.EngineWorkspaceBoundedTest` serves every helper spawn from a `/bin/sh`
  stub found on `PATH` as `python3`, because on the runner Python's start missed the 1 s bound in
  its `hold` and before its `seal` stub's pid write (#1043). After a 3260 ms run on `main`
  (run 1040, #1274), its "seal/1 still times out when the helper emits data faster than any poll
  tick" asserts the elapsed time under 5 s past its 1 s bound instead of 2 s, and so does the
  `DiskBoundedTest` test it mirrors, "run_rooted still times out when the helper emits data
  faster than any poll tick". Each test's emitter writes forever, so a deadline its output
  starves still fails at the 15 s test timeout. After a 6425 ms run on PR #1086
  (run 676, #1091), `Cinder.BoundedCommandTest` "run/4 with :check a check that halts kills the
  OS process and returns its reason" asserts the elapsed time under 9 s instead of 3 s, since its
  window times the stub's start. The bound stays below the call's 10 s timeout, so a halt that
  waits for that timeout before it kills the stub still fails it. After a 5336 ms run on PR #1214
  (run 900, #1216), "run/4 with :check a check interval longer than the timeout does not extend
  the deadline" asserts the elapsed time under 9 s instead of 3 s. The bound stays below its
  10 s check interval, which a deadline extended by that interval waits for. After a 12863 ms
  run on PR #1259 (run 1005, #1260) that still returned the check's halt, "run/4 with :check
  continuous output cannot starve the check" times only the check's own window against its 9 s
  bound, from the start of the check's first call to the return of its third. The stub's start
  and the kill fall outside that window. ExUnit's test timeout still counts them, so the test has
  no tag timeout and runs under the 60 s default. The bound stays below the call's 10 s timeout,
  so a second or third check that comes late, with the third starting 9 s or more after the
  first but before that timeout, still fails it. The test
  environment widens `Cinder.Library.Filesystem.Disk`'s `:disk_subprocess_timeout_ms` to 20 s
  (#945), four times the production bound, to give a slow start on a loaded runner headroom. In a
  test that does not set its own bound, a Disk timeout such as `{:error, :rooted_helper_timeout}`
  therefore means the subprocess did not answer for 20 s: look for a hang, or a runner far more
  loaded than usual, before calling it a flake.
- **Shared state.** Check order-dependent state before blaming a flake or a new test: the
  always-on `:login_pair` bucket of `Cinder.Accounts.IpRateLimiter`, keyed on the IP and the
  name (#686), and the suite-wide `Cinder.Subtitles.Fetcher` consuming another module's Mox
  expectations (#685). Give throttle tests unique names, and drain a shared worker with
  `:sys.get_state/1`: the Fetcher through `Cinder.LibraryStubs.await_subtitle_tasks/0`, which
  every `DataCase` and `ConnCase` test also runs when it ends ([testing.md](testing.md)). An
  `on_exit` failure on `:sys.get_state(Cinder.Subtitles.Fetcher, ...)` means a subtitle task
  was still running `DiskTask.timeout_ms()` after its test ended. That test queued it, or in
  the async phase another test running beside it.
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
- **Test-file warning.** A red `test` job whose `Result:` line counts no failure and is followed
  by `ERROR! Test suite aborted after successful execution due to warnings` failed on a warning
  that the alias's `test --warnings-as-errors` makes fatal. Above the `Result:` line, either a
  compiler `warning:` block names a test file and line to fix, or
  `warning: the following files do not match` lists a file under `test/` whose name ends in
  neither `_test.exs` nor `_helper.exs`, outside `test/support/`: rename or move it. After a
  compiler-warning abort, `mix test --failed` prints `There are no tests to run` and exits 0, so
  check the fix by running the file the warning names.
- **Trivy DB outage.** A red `container` job whose "Download the Trivy vulnerability DB" step
  fails on both repositories (`ghcr.io`, then `mirror.gcr.io`; #835, #841) is an upstream outage,
  not the diff. Outages have lasted hours. Re-run once another run's `CI / container` went green
  after the outage began; one successful download from your own machine proves nothing about the
  runner.
- **New advisory.** `dependency-audit` and `container` go red on every PR once an advisory is
  published after `main`'s last green run, whatever the diff touches. `dependency-audit` goes
  red the same way once a maintainer retires a Hex release that `mix.lock` holds. Read the CVE
  lines, or the `Retired:` block of a retirement, in the job log: when they name dependencies
  or base-image packages the PR does not change, the failure is baseline and blocks every merge
  until a fix PR lands. For a Hex package that `mix.exs` lists, Renovate writes that PR when a
  release within the package's `mix.exs` requirement, as Renovate reads it, fixes the advisory:
  its hourly run checks `mix.lock` against osv.dev and opens one PR per package, titled
  `... [security]`, which runs `mix deps.update <package>` and leaves `mix.exs` as it is
  (`renovate.json`). Renovate reads a `~> 0.N` requirement as below `0.(N+1).0`, where Mix reads
  below `1.0.0`. Look for the PR first with `curl ... "$API/pulls?state=open&poster=renovate"`,
  then read its `mix.lock` diff, whatever its title names: `mix deps.update <package>` unlocks
  the package and every package it depends on, and takes the newest release each requirement
  allows (`mix help deps.update`). On today's lock, `mix deps.update tidewave` moved 15
  packages, `tidewave` 0.6.0 to 0.9.2 and `req` 0.6.2 to 0.7.5 among them, where
  `mix deps.unlock tidewave` then `mix deps.get` moved `tidewave` alone. When the diff moves
  packages the fix does not need, close the PR and bump by hand that way. Otherwise review it as
  an upgrade of each package it moves, push a commit to its branch that adds the `### Security`
  fragment every advisory bump carries, named after the Renovate PR's number
  (`changelog.d/999-bandit-1_14_1.md` is one), and merge it under AGENTS.md "Merge authority"
  with `scripts/merge-pr --body-from=<sha of Renovate's commit> <n>`. These get the bump by hand
  too: a transitive package, a fix outside the requirement as Renovate reads it (any fix for
  `req` or `tailwind` today, locked past that reading), and a direct one before Renovate's PR
  opens. Look for a fixed release first and bump to it: a red `deps.audit` prints
  `First patched versions:` (`NONE` when no release fixes it yet). A red `hex.audit` names none,
  but the advisory URL it prints does, and `mix hex.info <package>` lists the recent releases.
  The bump rebuilds every dependency (**Dependency rebuild** below). `mix hex.audit` takes its
  accepted advisories from `ignore_advisories` in `mix.exs` (`hex/0`), each with a rationale
  comment. Renovate reads no such list, so an accepted advisory gets its PR once a release within
  the requirement, as Renovate reads it, fixes it; none does for `usage_rules` or Cloak today. On
  a retirement, `hex.audit` lists the release under `Retired:` as
  `<package> <version> - (<reason>)`, then the maintainer's message when there is one, and
  prints `Found retired packages` among its last lines. Bump off the release, as for an advisory,
  when a newer release without `(retired)` exists: `mix hex.info <package>` marks the retired
  ones among its eight highest versions, and `mix hex.info <package> <version>` opens on
  `This version has been retired:` for a retired one. Otherwise add an `ignore_retirements`
  entry beside `ignore_advisories`, pinned to the locked version (`<package>: "<version>"`) and
  with a rationale comment: a bare `:<package>` would also pass every later retired release of
  that package unreviewed. The audit then lists the release under `Ignored retired:` and no
  longer fails on it. For Debian packages Trivy flags that a fresh `apt-get upgrade` fixes, set
  the Dockerfile's `APT_REFRESH` to today's date so the cached layer rebuilds. A Trivy row whose
  target sits under `opt/ffsubsync` is a Python package: **Venv advisory** below. When fix PRs block
  each other, each red on an advisory another one fixes, carry them all on one branch: merge the
  others' branches into it, so it goes green alone. #885 carried #865 (`plug_crypto`, red on
  `container`) and #880 (`libbrotli1`, red on `dependency-audit`), and #865 also needed #885's
  own CI fix. Close each carried PR as superseded once the carrier merges; its `changelog.d/`
  fragment keeps its number. A carrier holds several commits, so `scripts/merge-pr --dry-run`
  stops and lists them: pass `--body-from=<sha of the carrier's own fix commit>`. Once the fix
  is on `main`, clear your own PR's red as "Re-running CI" says.
- **Venv advisory.** The Dockerfile's final stage builds the `/opt/ffsubsync` venv in the `RUN`
  that echoes `APT_REFRESH`, and Trivy lists each of its packages as a `python-pkg` target. The
  fix depends on what pins the flagged package to one version. The Dockerfile pins ffsubsync, and
  `docker run --rm --entrypoint sh <image> -c 'grep -H "^Requires-Dist:.*==" /opt/ffsubsync/lib/python3*/site-packages/*.dist-info/METADATA | grep -v "extra =="'`
  lists the pins the venv's packages set: ffsubsync's `auditok==0.1.5` alone today. A line whose
  `==` comes after its `;` is a platform marker, not a pin.
  - A package nothing pins: set `APT_REFRESH` to today's date, as for a Debian package. The `RUN`
    then installs the newest release the requirements allow. When the rebuilt image's scan still
    shows the row, take the ignore route.
  - ffsubsync itself: move the Dockerfile's `ffsubsync==<version>` and the dev shell's ffsubsync
    (flake.nix, from nixpkgs) to the fixed release in one PR.
    `nix develop . -c python3 -c 'import ffsubsync; print(ffsubsync.__version__)'` prints the dev
    shell's version. Check that every ffsubsync name `priv/ffsubsync_runner.py` reads or replaces
    still exists in the release, then measure the change as [subtitle-sync.md](subtitle-sync.md)
    says. When either pin cannot move yet or a check fails, take the ignore route with that
    reason.
  - A package another venv package pins (auditok, which every ffsubsync release from 0.4.12 pins
    to 0.1.5): find a newer release of the pinning package whose requirements allow the fixed
    version. For ffsubsync, take the ffsubsync path with that release; for a pinning package that
    nothing pins in turn, an `APT_REFRESH` bump installs it. With none, take the ignore route.
    Install only versions the pinning package allows, never a `--no-deps` override: no CI job runs
    ffsubsync from the image's venv, so nothing would catch the break.
  - pip: the `RUN` uninstalls pip from the venv, so Trivy finds none there. Debian's
    `python3-pip-whl`, the wheel the venv copies pip from, takes the Debian path.
  - The ignore route: add one entry per CVE to `.trivyignore` at the repo root, which the Trivy
    step reads through trivy-action's `trivyignores` input and prints under `Found ignorefile`
    in the job log. Above each ID, comment lines name the package and version, say whether
    Cinder's use reaches the vulnerable code (checked against the flags
    `Cinder.Subtitles.Sync.Ffsubsync` builds), and name the condition that removes the entry, as
    the comments above `ignore_advisories` in `mix.exs` do.
    `test/code_health/trivyignore_entries_test.exs` fails an entry that is not a bare CVE or GHSA
    ID, has no comment line right above it, or has comment lines that run on from the file's
    header with no blank line between.
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
  flag or not. To prove the fallback locally, put the same line in `config/test.exs`, run
  `MIX_BUILD_ROOT=$(mktemp -d) MIX_ENV=test mix deps.compile lazy_html exqlite --include-children`
  inside `nix develop`, which supplies `cmake`, then revert the line. A source build prints
  lazy_html's `-o .../priv/liblazy_html.so` link line and exqlite's `CC sqlite3_nif.o`, and a
  download prints neither. Without `--include-children`, the command fails on an empty build
  with `Unchecked dependencies for environment prod` and `the dependency build is outdated` for
  `elixir_make` and each NIF's other deps, because Mix then builds them from inside that NIF's
  compile and checks them against statuses it cached before they were built (#983). An OTP or
  Elixir bump moves three pins: every `erlef/setup-beam` step's `otp-version` and
  `elixir-version`, the Dockerfile's `OTP_VERSION` and `ELIXIR_VERSION`, and `flake.lock`'s
  nixpkgs. `test/code_health/beam_version_pins_test.exs` fails `mix test` when the first two
  differ, and its message says what to do when an upstream lags. No test reads the flake, so
  check the dev shell with `nix develop . -c elixir -e 'IO.puts(:code.root_dir());
  IO.puts(System.version())'`: the first line ends in `erlang-<OTP version>/lib/erlang`. When
  either version lags, run `nix flake update`. `nix eval --inputs-from . nixpkgs#...` reads the
  registry's nixpkgs, not the lock, so its answer says nothing about the dev shell (#1040).

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
  `main`, re-run only a job of `origin/main`'s head, or a cancelled job of a release PR's merge
  commit ([workflow.md](workflow.md) "Releasing" step 3). Find the run id as "Reading a run" says,
  then list the run's jobs with
  `curl ... "$API/actions/runs/<run id>/jobs" | jq -c '.[] | {id, name, status, attempt}'`.
- A red job at `attempt` 1 gets the re-run. A red test gets it only when it passes both checks
  of step 1 of **Flake** ("Judging a red run"), and a **Test-file warning** never does, since the
  same tree prints the same warning. The call is
  `curl -s -X POST -H "Authorization: token $FJ_TOKEN" "$API/actions/jobs/<job id>/rerun"`,
  which answers 204. A job at `attempt` above 1 was re-run already, by you or by another agent
  in a merge burst: wait on it while it reads `waiting` or `running`. A release PR's merge commit
  re-runs each `cancelled` job at any `attempt` ([workflow.md](workflow.md) "Releasing" step 3).
- When the POST answers anything but 204 on a PR, push an empty commit instead
  (`git commit --allow-empty -m "ci: re-run after <test> flake"`, which a squash merge drops;
  `scripts/merge-pr` then stops until you pass `--body-from=<sha of the fix commit>`). In
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
  `concurrency` group). On `main`, wait on the new head once one lands, except for the tag of a
  release, which needs the release PR's merge commit itself green ([workflow.md](workflow.md)
  "Releasing" step 3).

## Merge conflicts and translations

A branch syncs with `main` only on a conflict or a diff that touches `CHANGELOG.md` (AGENTS.md
"Merge authority"), or on a red that `main` clears ("Re-running CI", **Broken `main`**). For a
conflict in `priv/gettext`, follow [workflow.md](workflow.md) "Merge conflicts":
`scripts/gettext-fill.exs` refills the French msgstrs from the side you did not take.
