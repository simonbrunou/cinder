# Testing

- `mix test` decides when a task is done. Before you start, write the done-when as something
  `mix test` can check, then loop until it is green.
- When the issue carries a triage Agent Brief, the done-when names a test for each requirement in
  **Desired behavior**, each **Acceptance criteria** box and each rule that **Key interfaces** keeps
  unchanged. On #972, prod's mount layout, a `devino-hash` mount and `verify_legacy_selection`'s
  refusals were Desired-behavior requirements with no test until the Spec review, which cost
  a second review round. A clause that keeps today's behaviour ("as today", "still") or sets
  a count ("logged once") is a requirement too: its test goes red when a mutation breaks only
  that clause. A count's test sets up each way the count can repeat. On #1072, two "as today"
  fallbacks and a "logged once" had no such test until the Spec review. The count could repeat
  through two callers of one check or through two wanted languages sharing one track, and the
  second had no test until a re-check. Closing them took two more review rounds, about 25
  minutes. A state the change keeps from one run to the next, such as a poller's hold between
  ticks, reaches each such clause on every run it lasts, so the clause's test runs a later run
  too. On #1647
  (PR #1735) a held season group blocked the anime fallback only on the tick that set the
  hold. Later ticks left the held episodes out and ran the fallback, where `main` blocked it:
  a Spec finding, a fix commit and a re-check. A rule that Key interfaces keeps unchanged gets
  one test for each path of the new behaviour that reaches the rule, red when that path skips
  it. An existing test of the rule without the new behaviour does not count. On #1132, the brief
  kept the blocked-title rules (`AnimeParser`'s `blocked_titles`) unchanged. No test put a year
  after a blocked title. The new year reading then let a name with another alias's words before
  any year read as the series' own episode, where only the series' own year did before. The
  release-parser review found it, and the fix took about 20 minutes. Write that done-when
  down before the first full `mix test` (the first fence run on a docs-only branch, below),
  one line per requirement or clause with the test that covers it. Put the list in the PR body
  and paste it into the Spec reviewer's brief. On #986 and #950 such a clause reached the Spec
  review untested (about 1.5 and 10 minutes to fix), and #1207 lost 8 minutes to an untested
  "as today" clause and a false changelog sentence. When a run, a throwaway one included,
  shows a path on which a Desired-behavior requirement still fails, that path gets its own
  done-when line and its fix in the same PR. On #1290 a failed close of the staged file still
  dropped the new removal line. The fragment named that path as an exception, the Spec review
  flagged the requirement as partial, and the fix took a second full suite and a re-check:
  29 minutes from the run that proved it to the fix commit.
- A change that makes a predicate, such as a gate, accept one more state tests each path into
  that state, a reset that runs on a later read included, with the predicate asserted after
  each. On #1657 (PR #1780) a re-check fix let `IndexerState.passes_gate?/1` pass an ended limit
  with no failure in a row, tested on a limit after a success and on one after a timeout, never
  on one kept across an edit. The reset that a `config_version` rise applies on the next read
  keeps a running limit and zeroes the failures, so an indexer edited during a limit passed
  once the limit ended, with no answer under its new settings. The next re-check found it,
  and a third fix commit took the clause out.
- When code reads a stored value against a declaration that can change while the value stays
  stored, such as a definition's settings, a schema or an option list, test each path that
  leaves the value stored without its declaration, with a later declaration that names it
  again in the same test. Run that case through each code path that reads the value. On #1668
  (PR #1788) a Cardigann secret stayed stored after an update that removed its setting was
  applied or accepted. The next copy that declared it again crashed the whole apply with a
  `BadMapError`, and Accept's held hosts left out the hosts the running copy already named. The
  9 × 4 hold table never stored a key without its declaration, and the 72 mutants, every one
  killed but an equivalent one, never needed such a test: a Standards review found the crash,
  and a re-check the held hosts.
- A fix that keeps a behaviour across an Elixir or OTP upgrade answers like the old version on
  every input class, not only on the cases the issue names. Before review, run one table of
  inputs through the changed module's public functions, a row per input class that the changed
  code or the upgraded function tells apart. Run it on the merge base's code under the old
  version, then on the branch under both versions: every row matches the merge base's answer,
  except a row the PR body names with the answer you chose and why. The old dev shell is
  `nix develop <dir>` on a scratch directory outside any git checkout, holding the merge base's
  `flake.nix` and `flake.lock`, and `elixir --version` there prints the old version; pass
  `MIX_BUILD_ROOT=<dir>/_build` so the branch's `_build` stays. Write the table as a script for
  `MIX_ENV=test mix run --no-start`. For the merge base's side, save
  `git show <merge base>:<path>` to a file, and the script loads it with `Code.compile_file/1`
  after `Code.compiler_options(ignore_module_conflict: true)`. On #1102, the fix for Elixir 1.20.5's
  dropped redirect port answered unlike 1.20.4 on four classes: a non-HTTP scheme, a missing host
  and a non-UTF-8 host, each with an out-of-range port, and `//:70000/x`, which 1.20.4 resolved.
  Review flagged the first and the last one round apart, about 27 minutes from the first finding
  to the second fix. A re-check's table of 41 Locations over both versions found the last.
- A reader of untrusted input, such as a Cardigann definition (ADR 0005), returns its error on a
  malformed value and never raises. Its tests fill every slot of one fixture, then put each wrong
  shape in each slot in turn (null, a scalar, a list holding a scalar, a list holding null, an
  empty mapping, a mapping holding null, a list holding an empty mapping) and assert that no call
  raises. `test/cinder/indexers/definitions/loader_test.exs` "load/1 raises on none of seven value
  shapes in any slot" is the model. It runs its loads through `Task.async_stream` in 1.6 s on a
  quiet host and 2 to 4 s at a load of 61, where a first draft with nine shapes, one load after
  another, took 19 s. On #1664 the Standards review found that `[~]` in two list slots raised
  `BadMapError`, a fix round the sweep would have saved.
- A check that scans an untrusted pattern's text for a construct it refuses, such as
  `BoundedRegex`'s `\C`, has a test that runs every short string through each entry point. The
  strings are built from the backslash, the letters of the construct and of each escape that changes
  how the engine reads the characters after it (`c`, `Q` and `E` for `\C`), and the brackets of
  classes and groups. They are as long as the construct plus the longest escape that can hide it:
  five for `\C`, the length of `\c\\C`. Each string must be refused, or run without the harm the
  construct causes: for `\C`, a raise or text that is not UTF-8.
  `test/cinder/acquisition/indexer/cardigann/bounded_regex_test.exs` "no short escape or bracket
  pattern raises or gives text that is not UTF-8" is the model: `\ C c Q E [ ] ( )`, 66,429 patterns
  in under half a second. On #1670 (PR #1712) the Spec review found `\C`, and the re-check then
  found `\c\\C` hiding a real `\C` from the first fix's scan, a second fix round the sweep would
  have saved.
- A fix that escapes each value inserted into text a parser then reads as one string, such as
  the `$` to `$$` of `Cardigann.Filters`' `re_replace`, tests an insertion with the parser's
  syntax written right before it and right after it, each beside a value whose first or last
  characters can extend that syntax. For .NET replacement syntax that is a `$` written right
  before a value starting with `$0`, `0`, `&` or `{x}`, a `$1` written right before a value
  starting with a digit, and a `0` or a `$0` written right after a value ending in `$`. The test
  asserts the whole output: the written syntax's own expansion and the value's characters, in order.
  Where the output differs, the test pins it, and the claims and an issue name it. On #1728
  (PR #1789) neither the triage brief nor the first draft wrote a `$` right before an inserted
  value. A `$` written before an inserted `$0` paired with the escape's first `$`, so
  `${{ .X }}` gave `$` and the match. The cross-family Standards review found it, and narrowing
  the claims took a fix commit, a re-check and a second fix commit. #1786 holds the open
  decision.
- When review finds a second bug of one kind in the same code, the fix commit adds a sweep: a test
  over every combination of the inputs the bugs differ in, as `Cinder.Books.IdentityCollisionTest`
  enumerates its folds after six review rounds found one collision each. A streaming decoder gets
  its sweep in the commit that adds or changes it, before any review. A loop over
  `:zlib.safeInflate/2` reads at most 8 KiB of input a call (`INFLATE_IN_CHUNKSIZE` in OTP's
  `zlib.erl`), so its test runs every compressed length across several multiples of 8,192 bytes. Its
  input is built from bytes that do not compress, so the compressed length follows the input length,
  and each length gets each tail the code handles (none, a second member, a newline). Near those
  multiples zlib can answer an empty `{:continue, []}` before `{:finished, []}`. On #1658 a gzip NZB
  with a second member or a trailing newline was refused at 50 of 40,001 lengths, those whose
  compressed member ended 1 to 10 bytes past a multiple of 8,192. Two fix rounds each tested one
  length, and the re-check that swept the lengths stopped the branch under the two-round rule of
  `.agents/skills/fan-out-issue-threads/brief-template.md`.
- A commit that adds or replaces a scan over a fetched body, a regex or a walk of binary matches,
  gets a cap probe before any review. Each probe body fills the body's size cap with one shape:
  each token the scan stops on, with the bytes its pattern needs around it (`\ttype=password`, not
  `type=password`) and in each case form it folds (`<INPUT >`), repeated alone; each closed token
  alternating with each other token's hit (`<input>\ttype=password`); or a run a pattern repeats
  (blank space after `type=`). Send each body with the answer fields that route it to the scan, such
  as a trusted 200 with `content-type: text/html` for `DownloadCheck.check/2`. Print each body's
  answer, time and peak memory. Sample the memory from a second process every few milliseconds
  while the scan runs and keep the largest: `Process.info(pid, :memory)` plus the sizes that
  `Process.info(pid, :binary)` lists, each binary id counted once, since the first leaves out each
  binary over 64 bytes, such as a copy of the body. Run the probe on the branch's module and on
  the code it replaces at the merge base. Save that copy with `git show <merge base>:<path>`
  and rename its module, so both load side by side: a `Code.compile_file/1` of a file that
  defines the branch's module replaces the branch's code. When the merge base has no such code,
  or its copy raises on a body, compare that body with a body of the same size that holds no
  token, on the branch's module. A body that raises is a finding. Against the merge base's copy,
  so is a body that takes over 3 times its time or peaks at over 3 times its peak; against the
  body with no token, so is one that takes over 20 times its time or peaks at over 4 times the
  body's size. Fix or file each finding before review. The slow and large costs of #1658 below
  took 37 to 600 times the time of 20 MiB with no token, or 13 to 20 times the body's size,
  and the #1775 cost took 14 to 19 times the time of the version review had kept; the shapes
  review kept took at most about 12 times the no-token time and twice the body's size. A suite
  test cannot hold a time bound as tight as the comparison's on a loaded runner ([ci.md](ci.md)
  "Wall-clock tests"), so the timing stays a script. On #1658 (PR #1776) four re-checks in a
  row each found a new cost in the last fix: `SystemLimitError` on a 5 MB inline script, 20 s
  on 20 MiB of closed `<INPUT >` tags, 364 MiB for a list of every hit, then 1.7 to 1.8 s on
  `<input>` alternating with a hit, against 0.04 s with no token (#1775).
- A Cardigann engine rule that copies Prowlarr's .NET behaviour, such as a regex, a date format or
  the replacement syntax, takes its expected values from a `dotnet fsi` run. The test names the rows
  that came from it, the .NET call with its options and the SDK version, as the header comment of
  `test/cinder/acquisition/indexer/cardigann/dotnet_date_test.exs` does. From the checkout,
  `nix build --no-link --print-out-paths --inputs-from . nixpkgs#dotnet-sdk_8` prints the path of
  the SDK the repo's flake lock pins (8.0.427 on #1712). Run `<path>/bin/dotnet fsi <script>.fsx`
  with `TZ=UTC`, `DOTNET_CLI_TELEMETRY_OPTOUT=1`, `DOTNET_NOLOGO=1` and `HOME=<scratch dir>`, and
  keep the script and its output in that scratch directory. `TZ=UTC` makes .NET's local zone the
  engine's UTC: .NET gives a `zzz` row in local time and fills a layout with no date from the local
  date. The two `DOTNET_` variables keep the welcome banner, the telemetry notice and the
  certificate notice out of the output, and `HOME` keeps the SDK's first-run files, an HTTPS
  development certificate among them, out of your home directory. The first run in a new scratch
  home prints `An issue was encountered verifying workloads` on stdout, which changes no result. On
  #1712 such runs settled nine of the eleven choices its body records, such as the `zzz` forms and
  the `yy` pivot, and proved two review findings: `HH` and `hh` read one hour field, and `\c\` is
  the control character 0x1C in .NET and in `:re`.
- A bug fix starts with a test that reproduces the bug. Then make it pass.
- New functionality, such as a choke-point, a state or a writer, ships with a test.
- A field that code sets but no code reads yet, such as one a conversion copies for a later
  issue to store, gets a test that reads it. When only a private function sets it, move that
  function into a public one and assert its whole result: a test through the caller sees only
  what the caller reads. On #1644 (PR #1694) `Download`'s two private book conversions copied an
  indexer's source, name and credentials version that the download intent did not store yet.
  The Standards and Spec reviews each dropped those fields with the suite still green, and the
  fix moved the conversion to `Release.from_book/1`: a fix commit and a re-check.
- A fix or a feature in client JS (`assets/js/`) gets a test where it can run. A hook's logic
  that stubs can drive (its pushes and their replies or failures, a rejoin, the browser dialog)
  lives in its own module, such as `assets/js/passkeys.js`, and gets a Node test in
  `test/js/<module>_test.mjs`. `mix test` runs each such file through
  `test/cinder_web/js_hooks_test.exs`; run one alone with `node --test <file>` in the dev shell.
  On #1568 each bug in the passkey hooks surfaced only in a review round, then in a throwaway
  probe. Behaviour that needs a real page (a patch, focus, a WebAuthn ceremony) gets a case in a
  browser script under `.github/scripts/`, which `mix test` does not run: [ci.md](ci.md)
  "Browser scripts locally" says how to run one.
- A LiveView test asserts on an element, never on the whole view's HTML
  (`deps/phoenix/usage-rules/liveview.md`): `has_element?(view, selector, text)` or
  `view |> element(selector, text) |> has_element?()`. An `assert render(view) =~ text` passes on
  that text anywhere in the view, such as a flash or another season's panel, so it stays green
  once the element under test is gone (#1248). The whole view's HTML is what `render/1` and
  `render_async/1,2` return for a view, the `html` of `{:ok, view, html}` from `live`,
  `live_isolated` or `follow_redirect`, and what every event render returns: `render_click/2`
  and the others answer with the whole view even when given an element. Three forms stay
  allowed. A `refute` on the whole view, since absence anywhere is the stronger claim, and the
  settings tests use it to show a secret is never echoed. An assert on `render(element(...))` or
  `render_async(element(...))`, which return only that element's HTML. An assert on a
  function-component render (`render_component/2`, `rendered_to_string/1`) or a controller
  response (`html_response/2`, `conn.resp_body`), which has no view for `has_element?/3` to
  query. `test/code_health/live_view_raw_html_test.exs` fails a new whole-view assert, holds each
  older file at its count, and names in its header the forms it misses, such as HTML a test
  helper returns.
- A change to a shared component, such as `CinderWeb.CoreComponents.input/1`, gets a component
  test over each clause it touches before review, as
  `test/cinder_web/components/core_components_input_test.exs` renders one call site per clause
  that calls `input_attrs/3`.
  On #1551 (for #1546) the re-check of `dc891622` found `input_attrs/3` dropping a caller's
  `aria-invalid` when the input had no errors, which took a third commit and test.
- Each file Mix compiles (`elixirc_paths`: `lib/`, plus `test/support/` in the test env) defines
  one module, as `deps/phoenix/usage-rules/elixir.md` asks: "**Never** nest multiple modules in
  the same file as it can cause cyclic dependencies and compilation errors". An `.exs` test file
  is outside the rule: `mix test` loads it in memory, so its modules leave no `.beam` and no
  entry in `mix xref graph`. A review drops the finding on a module that only its own test file
  uses, nested or top-level. A module that two test files use goes under `test/support/`: two
  test files that define the same module name stop the load with
  `cannot define module ... because it is currently being defined`.
  `test/code_health/single_module_files_test.exs` fails
  a compiled file with a second module and names in its header the forms it misses.
- Run a red run, a mutation check or a throwaway test with `mix test.unchecked`, which takes the
  same arguments as `mix test` (`<file>:<line>`, `--failed`, `--only`, `--seed`). It creates and
  migrates the test database, then runs ExUnit in one process, never in the partitions a bare
  `mix test` starts (AGENTS.md "Commands"), and without the `mix test` alias's gates: compile
  warnings, the format check, `credo --strict` and test-file warnings. A mutant that leaves a
  variable or helper unused, trips the type checker or nests too deep for Credo still reaches
  the `Result:` line. Compiler warnings still print, and a failing test still exits non-zero.
  The format check and Credo do not run at all, so `mix test` stays the only "done" gate. On
  #1149 those gates stopped 6 of 14 mutants before ExUnit, about 13 minutes of rewrites, and
  #851 records 22 more threads that lost runs to them. Both aliases stop before ExUnit with
  `mix test: no such test path: <path>` when a path under `test/` names no file or directory.
  Mix itself fails only when none of the given paths matches: on #786 a fence run with one
  mistyped file exited 0 without running it. A `<file>:<line>` can select a neighbour of the
  test you meant, as a bullet below says.
- Run a list of one-edit mutants with `scripts/mutation-check <file> <mutants.json> <test>...`.
  Its header gives the JSON shape, the checks it makes before the first mutant runs, the
  verdicts and the exit codes. Read the lines it prints under each verdict: the lines the edit
  removed and added, then the failed tests of a kill, each with its message, up to 10 lines, and
  the `code:` lines ExUnit prints, or the errors of a run with no result. A kill's lines come
  from the failure record that `Cinder.MutationFailures` writes, so a line a passing test prints
  never reaches them (#1532). A test that runs another `mix test` adds that run's failures to the
  record.
  On #702 a hand-written loop chained `diff && run_suite` and ran no mutant, and #1230, #1250 and
  #1254 each wrote a loop by hand.
- Select each test a mutant must kill by name: after the test file, give one
  `--only "test:test <name>"` per test. `<name>` is what a `--trace` run prints after `* test `:
  the test's name, prefixed by its `describe` block's name and a space when it sits in one. Put
  a `\` before each `$`, backtick or `"` in the name. A mistyped name among several drops its
  test, so `scripts/mutation-check` exits 2 when the control passes fewer tests than it has
  names. When no name matches, the control ends on `Result: 0 tests` and the script exits 2. The
  script also runs nothing and exits 2 on a `<file>:<line>` that starts no test or `describe`.
- A `<file>:<line>` runs the closest test that starts at or above that line, or the whole
  `describe` when the line is the `describe` line itself. A line above the test's own, such
  as the blank line before it, or one that an edit above the test shifted, runs a neighbour.
  `scripts/mutation-check` refuses a line that starts no test or `describe`, but a shifted
  line that lands on another test's first line still tests that test. A line above a file's
  first test, other than a `describe` line, runs no test, and `mix test.unchecked` exits 0 on
  `Result: 0 tests`. On #1479 (for #1460) `requests_test.exs:129` named the blank line above
  that PR's new test at line 130. `--dry-run` on `6a5cd9ea` shows that line selects the test
  at line 114, and #1502 records three mutation runs there that checked the wrong test. Before
  a direct `mix test.unchecked <file>:<line>` run, check that `--dry-run` lists the test's own line.
- Mutation-check every negative assertion: break the guard it fences and watch the test go red.
  Pair a refute on a collection with a positive control that proves the collection is the right
  one and populated, and refute the stem, not a guessed inflection. After a rename that changes
  how an identifier is built, re-run the check on every negative that names it.
- When two guards stop the same effect, the mutant that breaks one survives the other. The
  negative test then also refutes what only the other guard leaves, such as the value it returns
  or a log line it writes. On #1659 (PR #1785), `IndexerStatus.record/3` drops the answer of a
  grab whose configured indexer was deleted during the fetch, and the foreign key would refuse
  the insert anyway. The mutant that skipped the drop survived until the test also refuted the
  `not recorded` warning that the refused insert logs.
- A limit the change adds (a lifetime, a rate-limit window, a cap) gets a test that pins the
  value the app runs with, without waiting it out: `PasskeyChallengesTest` "an entry lives 3
  minutes by default" asserts the stored expiry, and `IpRateLimiterTest` "the :passkey_options
  window lasts one minute from its first request" moves the window's start to 59 s and 60.001 s
  ago. The expected value is a literal in the test. A test that shrinks the limit with `put_env`,
  or takes its expected value from the module it tests, passes at any value. On #1568 every
  expiry test set `:passkey_challenge_ttl_ms`, no test reached the end of the `:passkey_options`
  window, and the cap test filled the store to `max = PasskeyChallenges.max_entries()`. Mutants
  that set the TTL and the window to a day and the cap to ten times its value survived until the
  Spec review, and closing them took a test per limit.
- When a test fixture or helper defaults a value to equal another value the code compares with,
  a test sets them apart with an input that one value admits and the other refuses, and asserts
  the result. The mutant list holds a mutant that reads the other value. Every test that keeps
  the default passes that mutant, and so does one with no input that one value admits and the
  other refuses. On #1731 (PR #1787), `answer/3` in `Cinder.Indexers.DefinitionsTest` defaults
  its `:max` option, the answer's `MAX_VERSION`, to 12, the engine's schema version. The Spec
  review's mutant that took the count's ceiling from `MAX_VERSION` instead of the engine's
  version survived every test, an older one with `MAX_VERSION` 11 and files only in v11 and v13
  included. The fix took a test with files in v13 under `MAX_VERSION` 13 and in v12 under 11,
  a fix commit and a re-check.
- A negative test of code that rescues every raise, such as `Subtitles.fetch_missing/3` (its
  `fetch_one/6`) or a poller's `poll/1` (`isolate/2` in `Cinder.Download.PollerSkeleton`), stubs
  the action to succeed and to send the test process a message, then runs `refute_received` on
  that message once the synchronous call returns. A `deny/3`, an unstubbed mock or a stub that
  calls `flunk` raises inside that rescue, so the test stays green when the code acted. A poller
  runs its units in its own process, where `self()` is the poller. Make the stub reach that
  process, bind `test_pid = self()` in the test body and `send(test_pid, ...)` from the stub, as
  `Cinder.Download.TvUpgradeArbitrationTest` does with `setup :set_mox_global` and
  `watch_grabs/0`. `poll/1` is a `GenServer.call` that replies after the units run, so the
  message is in the test's mailbox when it returns, unless a unit hands the work to another
  process without waiting for it. An entry point that only enqueues, such as
  `Subtitles.fetch_after_import/4`, returns before the work runs. On #1412 (PR #1423), a `deny/3`
  on the subtitle download survived the mutant that let the download run, and the reporting stub
  killed it (`Cinder.SubtitlesTest`, "an ID result leaves an ID-matched sidecar already in
  place").
- `:sys.get_state/1` on a running server orders only the test process's own messages to it, as
  `Cinder.SyncWorkerHelpers.cast_units/2` says. A cast from a process the test just started can
  reach the server after the test's `:sys.get_state/1` call: in four runs of a probe that started
  a `Task` to cast and then read the state, 999 or 1,000 casts of 1,000 were missing. Before a
  test counts on the order of requests that such processes queue, it polls the state until each
  one shows, as `await_seen/3` in `Cinder.Acquisition.IndexerSource.Native.LeaseTest` does. A
  `refute_received` of a message that a granted process would send after the grant passes while
  that message is still on its way, so read what the server decided from its state instead,
  as that test's `holder_pid/2` reads the slot's holder. On #1770 (for #1655) the Standards
  review found both in the first `LeaseTest`, and the fix took a review round and a re-check.
- A test that sends a LiveView a message with `send(view.pid, msg)`, where the view's
  `handle_info/2` passes it on to a component with `send_update/3`, calls `render(view)` once
  before the call that checks the component. Each `render/1` or `has_element?` call pings the view,
  then reads the HTML the view has sent back. `send_update/3` sends the update to the view's own
  pid, so it can queue behind the first call's ping. When it does, and its HTML reaches the test
  after that call reads, the call sees the component as it was before the message. A `refute`
  there then passes on the unfixed code. The second call's ping queues behind the update. Each
  further message on the way, such as a `send(self(), ...)` before the `send_update/3` or a
  `send_update/3` from the component's `update/2`, takes one more `render(view)`. No count of
  calls waits for `send_update_after/4`: poll a positive assert until it holds, as `eventually/2`
  in `CinderWeb.SettingsIndexersTest` does, before the `refute`. On #1660 (PR #1797) the red
  run of "a reset names no Test that still runs" in that module passed while its `refute` was
  the first call after the send. On that page a probe's first call found the reset's notice in
  0 of 20 runs, and its second call in 20 of 20.
- When the code computes a value that a message or a return reports, such as an elapsed time or
  a count, the mutant list holds mutants that report a wrong value, such as a constant and `0`,
  besides one that drops the value. The test pins the value, or bounds it on both sides where it
  varies: for an elapsed time, a floor the test sets up and a ceiling from clock reads around
  the call. A `Process.sleep/1` inside the timed span sets that floor. It waits for no process,
  so the usage rules' advice against sleeping to wait for one (`deps/phoenix/usage-rules`)
  does not apply. On #1404 (for #1361) the test matched only the elapsed time's digits: a
  Standards review found a constant surviving and a re-check found `0` surviving, 23 minutes
  from the first finding to the last fix.
- When a change gives callers an argument that picks a rule set, such as a kind atom or a mode,
  the mutant list sets each call site to each other value the argument takes, besides the
  mutants of the module behind it. A mutant inside the module leaves a caller that passes the
  wrong value untested. On #1411 (PR #1422), the mutants passing `:standard` to
  `EpisodeNumbering` at the anime import, the reservation and `Anime.scene_seasons/2` survived
  their test files while every mutant inside the module was killed. A Spec review found them,
  and the fix took a test commit and a second mutation run.
- A table test built with `for` whose answers can be `false` or `nil` binds each row's whole
  cell and filters on it: `cell = {input, f(input)}, cell != {input, expected}`. A bare
  `answer = f(input)` clause is itself a filter, so every row whose answer is `false` or `nil`
  drops out unchecked. On #1415 (PR #1436) the `sidecar?/2` table bound only the answer. One
  mutant compared all of wanted `pt-br` with a name's language, so it refused `M.pt.srt`. That
  row dropped out, the mutant survived `scripts/mutation-check`, and it took a test rewrite and
  a second mutation run.
- Run the branch's new tests, or a throwaway test, against the merge base's code with
  `scripts/test-at-base <merge base> <lib file>... -- <mix test.unchecked argument>...`: the red
  run before a fix, and the runs that prove a changelog sentence about what Cinder did before it.
  It puts each named file back as the merge base holds it and restores it afterwards, also on a
  signal. Its header gives the lib files to name and the exit codes. On #788 and #1322 the swap
  and the restore were done by hand: about 6 minutes on #788, and three hand swaps on #1322.
- Before a change to what a parser or check accepts (a link, a date, a host), add the input
  shapes the old check accepts to a test of their own, apart from the refused inputs, then run
  that test file through `scripts/test-at-base` against the last commit that holds the old
  check: the merge base, or the branch's commit before the change when the branch added the
  check. Every accept row that passes there must pass on the branch, unless the change means to
  refuse it. For an indexer link, those shapes are the accept rows of
  `Cinder.Acquisition.Indexer.Newznab.ItemsTest`. On #1653 (PR #1755) the link check went from a
  regex to `URI.new/1` with a host pattern. The pattern refused `http://prowlarr_app:9696/...`,
  and `URI.new/1` refused a query holding `|`, `[`, `]` or raw UTF-8, which the regex took. A
  re-check round found both.
- A throwaway test, one that only reports what the code does, runs with `mix test.unchecked`.
  Before you edit an existing test file, copy it outside `test/` and restore it after the run;
  delete a new file. Report from the test body with
  `flunk(inspect(value, limit: :infinity, printable_limit: :infinity))`, since `inspect/1` cuts
  long lists and strings.
- A lock test runs the waiter in another process than the holder: the lock id carries `self()`
  and `StagedImport.run/1` is re-entrant, so a waiter in the holder's process never blocks. A
  short `refute Task.yield(task, 100)` shows it blocked (`Cinder.Library.StagedImportTest`,
  "run/1"). After the release, the waiter wakes at its next `:global.trans/2` retry, a random
  sleep whose ceiling doubles from 250 ms to 8 s. What sets the await is how long the lock stays
  held after the waiter starts: the default 5 s covers a few hundred ms, and a hold of seconds
  needs about 15 s. When the holder reaches a Disk subprocess, as a whole `TvPoller.poll/0`
  import does, the waiter awaits with `Cinder.Test.DiskTask.await/1` instead (next bullet).
- A test file that reaches a `Cinder.Library.Filesystem.Disk` subprocess (through Disk,
  `stub_with(FilesystemMock, Disk)` or `Cinder.Test.BarrierFilesystem`) waits past the test-env
  Disk bound. It awaits every task with `Cinder.Test.DiskTask.await/1`, and passes
  `Cinder.Test.DiskTask.timeout_ms()` to every `assert_receive` of a `{:filesystem_barrier, ...}`
  message and of any other message its task sends after a Disk call. `Task.await/1`'s 5 s
  default, and the 15 s waits it replaced, failed a slow helper start as a `Task.await` exit
  (#1012). A barrier message comes only after the Disk calls the paused task ran first, so a 5 s
  or 15 s wait fails the same start as a missing message (#1034). Two fences scan each test file
  and each `test/support` module that names `BarrierFilesystem` or `Filesystem.Disk`.
  `test/code_health/disk_task_await_test.exs` fails a `Task.await` or `Task.await_many`, except
  one inside `catch_exit/1`, the form kept for a task the test already killed, and except in
  `Cinder.Test.DiskTask` itself, whose `await/1` is the wrapper.
  `test/code_health/disk_barrier_wait_test.exs` fails a barrier `assert_receive` whose timeout is
  not `DiskTask.timeout_ms()`. It sees only barrier messages.
- A migration test that runs on its own `Ecto.Repo` starts it with
  `Cinder.MigrationRepoHelpers.start_repo!/2`, which waits for the repo's one connection to open.
  A statement sent right after `start_supervised!/1` queues behind that open, and on a loaded
  runner the pool dropped it on `queue_timeout` (#963). `test/code_health_test.exs` fails on a
  private repo started another way.
- Ecto applies each migration version to a test database once. `mix test` and
  `mix test.unchecked` migrate their database first and record each version they run, so a later
  edit to that migration never runs there. Write the body of a migration that
  `mix ecto.gen.migration` creates before the next test run: on #1645 the empty `change/0` ran
  first, and the tests that read `blocked_releases` then failed with
  `no such column: b0.indexer_source`. After any edit to a migration a test run already applied,
  drop each test database and let the next run migrate it afresh: `MIX_ENV=test mix ecto.drop`
  drops `cinder_test.db`, and `MIX_TEST_PARTITION=<n> MIX_ENV=test mix ecto.drop` drops
  `cinder_test<n>.db`, for each `<n>` that `ls cinder_test*.db` lists.
- A boot-time DB read from any process but `Cinder.Supervisor` stalls every `mix test` until the
  pool drops it: 60 to 90 s at the test env's `queue_target` (#1018). When you add a read at
  boot, gate it off in `config/test.exs`, as `warn_unprotected_at_boot` does. When you change
  `Cinder.Repo`'s test pool options, time the boot before and after. The cause:
  `Cinder.Settings.start_link/1` reads the DB inside the supervisor, and the Sandbox boots in
  `:auto` mode, so the supervisor owns the one connection until `test_helper.exs` switches to
  `:manual`. On the dev host, `MIX_ENV=test mix run -e ':ok'` boots in about a second, and a
  one-file `mix test` takes about 12 s, 10 of them Credo. A one-file run past 20 s whose ExUnit
  run takes under a second points at such a stall.
- Tests never hit the network or a real service. `config/test.exs` points each external-service
  behaviour at its Mox mock, so a test that needs service behaviour sets an expectation on the
  mock. The behaviour list is in [architecture.md](architecture.md). `Cinder.Acquisition.Indexer`
  is the exception: the test env keeps the `:indexer_adapters` map of `config/config.exs`, the
  real Newznab and Torznab adapters, and sends their requests to the `Cinder.NewznabStub`
  `Req.Test` plug, which `Cinder.NewznabFixtures.route/1` stubs. A test that needs another map
  sets it for its run with `Cinder.ConfigCase.put_env/2`.
- To show the request an adapter sends outside the suite, for a PR's test path, run a script with
  `MIX_ENV=test mix run --no-start` against a local listener that logs each request line, such as
  Python's `http.server`. `--no-start` starts neither Cinder nor its dependencies, so the script
  first runs `Application.ensure_all_started(:req)`, then starts `Cinder.HTTPPolicy.TaskSupervisor`
  with `Task.Supervisor.start_link/1`, since `HTTPPolicy.bounded_request/2` runs each request under
  it. It points the config key the adapter reads at the listener with `Application.put_env/3`,
  whose new list drops any `req_options` plug `config/test.exs` sets there. It calls the adapter
  module itself, since `config/test.exs` points each external-service behaviour at a Mox mock,
  except `Cinder.Acquisition.Indexer`, whose adapters send their requests to a `Req.Test` stub. On
  #1627 (PR #1701) the first run exited on the missing supervisor, and the first draft of this
  bullet left out `:req`. For a Newznab or Torznab search through `IndexerSource.Native`, run
  `scripts/dev-native-search.exs` instead: it serves its own listener and prints each request
  line ([code-navigation.md](code-navigation.md)).
- Inject a one-time filesystem failure with `Cinder.Test.BarrierFilesystem.fail_once/1` or
  `fail_in_order/1`. Each fails the test when the failure never fired. A failure armed by hand
  with `Application.put_env` gets no such check: keep that for a failure that must stay armed.
- A failure fires on the first matching operation whose source contains `source_contains` and
  not its optional `excludes`. A bound reports the path it was opened or created at as its
  source. Only a bound created outside the library roots reports its `/proc/<pid>/fd/<n>` path.
  A file's path contains its directory's, so a failure meant for a directory's close excludes
  the files inside it, as `directory_close_failure/1` in `Cinder.Test.SidecarTransactionCase`
  does.
- The identity probes that verify a subtitle exchange close bounds on the same paths. Arm a close
  failure meant for after the exchange from a barrier, as `fail_close_after_exchange/4` in
  `Cinder.Test.SidecarTransactionCase` does.
- A barrier armed with `phase: :before` also matches the operation's after-phase pause, so on an
  operation that pauses on both sides (every one `BarrierFilesystem` pauses before, except
  `chmod`, `mkdir_exclusive` and `open_bound`) the task pauses twice. Give it `once: true`, as
  `use_barrier/1` in `Cinder.Test.SidecarTransactionCase` does, or the task waits on a second
  release the test never sends.
- In a mocked-filesystem test, an `lstat` stub that returns a `%File.Stat{}` sets
  `type: :regular`: the struct defaults it to `nil`, which `Cinder.Library.StageEngine` refuses at
  the destination as `{:unexpected_destination_type, nil}`. For a fresh import, use
  `Cinder.LibraryStubs.stub_import_ok/1` or answer `lstat` with its `import_lstat/2`. For an
  occupied destination, answer that path with `type: :regular` and fall back to `import_lstat/2`
  for the rest. Match a staging candidate with `candidate_path?/1` or `candidate_marker/0`, never
  the literal, and settle a staged import as a catalog writer does with `commit_staged/1`.
- A test that reaches `Cinder.Subtitles.SidecarTransaction.replace/4`, such as a subtitle fetch
  that commits its sidecar, needs a real library: its `AtomicFile` reads and stats the staged
  and target files with `File` calls, which no `FilesystemMock` stub answers. Point the root
  settings at `tmp_dir`, `stub_with(Cinder.Library.FilesystemMock, Disk)`, then re-stub only what
  the test is about. `use Cinder.Test.SidecarTransactionCase` gives a `SidecarTransaction*Test`
  module a `tmp_dir` library on the real `Disk` instead, set as the `:filesystem` itself rather
  than through the mock.
- Release a barrier inside the log capture whose output the test asserts: send `{ref, :continue}`
  from the `capture_log/1` or `with_log/1` function. The paused task logs as soon as it resumes,
  so on a slow runner a release before the capture prints the warning to the console and the
  capture reads `""` (#969). `code_health_test.exs` fails on a release followed by a capture in
  the same block.
- A test that asserts an `:info` or `:debug` line first lets that level through the Logger, in an
  `async: false` module, with an `on_exit` that restores it: `Logger.put_module_level/2` on the
  module that logs, as `Cinder.Books.BibliographyRefresherTest` does, or `Logger.configure/1`
  with `:level`, as `Cinder.Notifier.LogTest` does. The suite's Logger level is `:warning`
  (`config/test.exs`), and the `:level` option of `capture_log/2` and `with_log/2` filters
  only its own capture, so while neither the module level nor the Logger level admits the line,
  the capture reads `""` whatever its own `:level`. On #1658 the author found this only after
  a red run and a search of other tests.
- A new repo-wide fence, a test that scans the sources for a pattern, goes in its own file under
  `test/code_health/`, not in `test/code_health_test.exs`, whose test count
  `Cinder.CodeHealth.FenceFilesTest` caps. Its header says why.
- A fence matches the scanned language's syntax, not its lines or substrings. An Elixir fence
  walks the AST from `Code.string_to_quoted/1` (`code_health_test.exs`). A fence on which modules
  a module calls walks instead the Erlang abstract code in the module's `.beam` debug info, where
  the compiler has expanded every alias and import
  (`test/code_health/series_identity_sync_calls_test.exs`). A workflow fence parses the YAML
  with `yaml_elixir`, and `test/code_health/ci_browser_wait_test.exs` tokenizes the Python CI
  scripts. For a file whose grammar has no parser in the deps and is too large to
  copy, such as a Dockerfile, read only the part of the file that holds what the fence checks
  and where each line is one whole statement, and fail on every form there that the reader
  cannot read. `test/code_health/beam_version_pins_test.exs` reads only the lines before the
  Dockerfile's first `FROM`, where Docker allows only `ARG`, and fails on a line there that
  continues onto the next. When no such part holds the pin, scan the whole file and fail on
  every mention but the pin line and the one reference form:
  `test/code_health/tailwind_dockerfile_pin_test.exs` does so for `ARG TAILWIND_VERSION`, after
  the builder's `FROM`, and allows only `${TAILWIND_VERSION}`; start a new whole-file fence from
  its fixtures. Give a fence fixtures for the
  pattern split across lines and for the pattern inside a comment and inside a string. On #1039,
  a per-line fence flagged prose, then a trailing comment, and missed a call split across lines:
  two re-check rounds, about 40 minutes, before it tokenized. On #1040, a Dockerfile reader
  that copied BuildKit's heredoc, continuation and escape rules took two review rounds,
  14 minutes, before it took that route. On #1077, the whole-file reader and its first two fixes
  passed forms the issue's rules let through: a name spelled with quotes, escapes or expansions,
  which Docker or the shell resolves; a `#` line in a heredoc body, which Docker keeps; an escape
  character where Docker applies none (`` ` `` with no `# escape=` directive, or the end of a
  heredoc body line). Three review rounds, about 50 minutes from the first finding to the last
  fix, found them.
- Before review, list each form the sources use to reach a fence's pattern (`rg` for the call,
  its wrappers and its aliases) in the PR body, and paste the same list into each reviewer's
  brief: a review that runs before the PR opens has no body to read, and on #1261 the Standards
  review reported the list unchecked. Give each form the fence catches a fixture. Name
  each form it misses in its header, after an "include" lead-in such as
  `test/code_health/req_stub_sleep_test.exs`'s "Forms the walk does not follow include:", and
  show each one with a fixture or a throwaway probe. On #1219 the Standards review found that
  fence's header promised less than its walk enforced, the Spec review found a `defp stub(fun)`
  wrapper that hid 50 SABnzbd stubs from it, and three re-check rounds found its header's list of
  missed forms false or incomplete: about 33 minutes from the first finding to the last fix.
- An Elixir source-walk fence on some functions of one module starts its form list from the
  forms the header of `test/code_health/manifest_writers_test.exs` catches and misses. On #1481
  a Spec review, a Standards review and a re-check found `require ..., as:`, the quoted atom,
  `Kernel.defdelegate` and an `as:` alias of the quoted atom one round at a time: about
  32 minutes from the first finding to the last fix.
- Give each rule a fence's own parser applies a fixture at its edges and a mutant in
  `scripts/mutation-check` that the fixture kills: a list or range syntax gets an empty, a
  reversed and a mixed entry (`fun/4..1`, `fun/1..4,3..1`); a joiner of wrapped lines gets each
  separator at the end of one line and at the start of the next; a marker that skips one item
  gets a line with two items, in one span and in two. On #1373 (`doc_names_test.exs`) a Spec
  review and two re-check rounds found these one at a time: about 24 minutes from the first
  finding to the last fix.
- When an adapter parses an external service's body into a list that admits or refuses someone,
  give it, before review, one fixture per name it reads (root, element, attribute or key) with
  that name changed. For an entry's element, attribute or key, change it in a body holding only that
  entry and in one holding it beside valid entries, the count matching the valid ones only. Add
  one per count the body states, such as a `size` attribute, with it missing or wrong. Each
  fixture expects the adapter's refusal, such as `{:error, :unexpected_response}`: a dropped
  entry reads as someone refused, and the caller acts on it. On #1407 (for #1212) the plex.tv
  share list's parser returned fewer shares instead of refusing for a renamed element or
  attribute, then for a renamed element under a root without `size`, then for a share whose
  attribute read `userId` beside valid ones. A Spec review and two re-check rounds found these
  one at a time, and a third found the parser's comment wrong: about 25 minutes from the first
  finding to the last fix.
- The fence run is the alias's compile, format and Credo gates with the repo-wide fences:
  `mix test test/code_health_test.exs test/code_health` (under 30 s). Before a branch's first
  full `mix test`, do the fence run with each test file the branch added or changed appended. A
  bare `mix test` runs the fences first too (AGENTS.md "Commands"), but it runs the branch's own
  test files only in its partitions.
- A docs-only branch does the fence run before its first push, in place of a full `mix test`. Each
  file it changes fits the first case of the review-fix bullet below; despite the term, that case
  also takes in scripts, workflows and `.agents/skills/` files. Append the test files that case
  adds for each changed file. CI's full run on the PR's pushed SHA then meets a done-when that
  asks for `mix test`, and `scripts/merge-pr` merges only once that run is green. A review fix
  commit or a merge of `origin/main` that leaves the branch docs-only takes the same fence run
  before its push. A changed file outside that case, or one that case sends to the fourth case,
  makes the branch owe its first full `mix test` before its next push. The maintainer decided
  this on #1469.
- A full `mix test` ends with its slowest partition, and the dev host's load lengthens it. On
  #1473, at a load average of 11 to 24 on its 16 CPUs, a 4-partition run of `mix test.unchecked`
  took 375 s, without the gates and before #1498 split its slowest module. On #1503 two full runs,
  gates included, started at a load of 61 and 64 and took 625 s and 755 s. Both ran past the
  600 s cap of one foreground Bash call, so start a full run in Claude Code with
  `run_in_background` and `timeout: 1800000`. A background call stops at its `timeout`: on #913
  a run cut off at 600000 cost about 20 minutes to the green rerun. On #1205 it ended red on a
  new test's `assert {:error, :unexpected_response} = HTTP.server_machine_id(), message`, which
  `test/code_health/assert_match_message_test.exs` rejects: 8 minutes for what the fence run
  reports in 16 s. At load 61 and 64 the two #1503 runs also failed seven tests the branch did
  not touch, on time limits and lost database connections, and each passed when run again outside
  the full suite (#1456, #1510 to #1512). After a full run that failed tests,
  `mix test.unchecked --failed` runs only those tests again; [ci.md](ci.md) "Flake" says when a
  failure counts as a flake. To diagnose a flake that only full runs have shown, loop the failing
  file with `mix test.unchecked --repeat-until-failure <count> <file>` beside the contention you
  suspect (a logger flood or log captures turned on and off from a throwaway test, a CPU hog),
  with a probe that prints the awaited message's latency. More full runs make no loop: on #1463
  a one-process and a partitioned run took 18 and 10 minutes at a load of 20 to 65 and never
  repeated the failure.
- Once a full `mix test` passed on the branch, a review fix commit takes a short run before its
  push, never a second full suite: the fence run with the test files the four cases below add for
  each file it changes. CI runs the full suite on the push, which runs every file these short
  runs skip, and the PR merges only once that run is green (AGENTS.md "Merge authority"). The
  maintainer decided this for every thread on #1553. On #905, #945 and #873, another full run on
  such a fix took 4 to 5.5 minutes of the CPU the host's agent threads share, and on #903 three
  took about 20 minutes. On #942, #986 and #1193, full runs after a fix to `.agents/skills/`
  Markdown, a `docs/adr/` file or `ci.yml` cost each thread about 7 minutes, though no test
  outside the fence run reads those files.
  - A file that the suite neither compiles nor loads: one outside `lib/`, `test/`, `config/`,
    `priv/` and `deps/` that is not `mix.exs` or `mix.lock`, and not under `docs/audits/` or
    `specs/` (the fourth case). Add each test file that reads it. A test can read a file via a
    directory above it, as `ci_browser_wait_test.exs` globs `.github/scripts/**/*.py`, so
    search for the file's path and for each directory above it:
    `rg -l -F -e docs/adr/0001-x.md -e docs/adr -e docs test`. A listed file that the fence run
    runs (`test/code_health_test.exs`, `test/code_health/`) needs no reading. Read the hits of
    each other listed file with `rg -n`, and add that file when a hit hands the changed file's
    path, or a directory or glob that holds it, to code that reads, lists, stats or runs files:
    `bounded_command_lookup_test.exs` looks up `scripts/seed-worktree` as an executable. A hit
    in prose (a comment, doc text, a message, a test name, a URL), a path to another file, a
    path under a temporary root or a map key adds nothing. When you cannot tell, add the file.
    A hit in a `test/support/` file that reads the changed file sends it to the fourth case,
    since any test that uses that file can read it. The search misses a root glob (`"*.exs"` in
    `comment_line_length_test.exs`), a glob that splits a directory name
    (`.{forgejo,github}/workflows/*.{yml,yaml}` in `beam_version_pins_test.exs`) and a read
    through `lib/` (`Cinder.Changelog.check(".")` in `code_health_test.exs`). Only fences read
    that way today, and the fence run runs them.
  - Ordinary `#` comments in `.ex` and `.exs` files, and `@doc` and `@moduledoc` text in `.ex`
    files of modules no `doctest` names. When a comment or doc text under `lib/` changed, add
    every file that `rg -l '"lib/' test` lists (about 2 minutes): some of them scan `lib/` with
    patterns that a comment or doc text can match.
  - `_test.exs` files. Add each changed test file that still exists, and every file that
    `rg -l <path> test -g '*_test.exs'` lists for each changed path and for a renamed file's old
    path (`git diff --name-status -M HEAD^` shows both once the fix is committed).
    `books_b0_contract_test.exs` reads test names out of the files it names, and apart from it
    only the fences read the test sources. A test file can still break another one through
    shared state, such as an `async:` flag or a config key it no longer restores. On #1123, four
    full runs after test-only fixes took 21 minutes, and one on #1127 took 7 minutes.
  - Any other file, such as code under `lib/`, `config/` or `priv/`, `mix.exs`, `mix.lock`,
    a `test/support/` file, a file that a `test/support/` file reads, or the doc text of a
    module that a `doctest` names. Add each test file that `rg -l` lists under `test` for the
    changed module, function, config key or file name. A module aliased in a `{...}` group shows
    only its last name segment, so search that segment too. A `test/support/` file the search
    lists adds each test file that names its module. Add every file that `rg -l '"lib/' test`
    lists for a change under `lib/`, `test/cinder/books_b0_contract_test.exs` for a file under
    `docs/audits/` or `specs/`, and each file `rg -l -F priv/gettext test` lists for a gettext
    catalog. For each changed string literal or msgstr, add each file that `rg -l -F` lists under
    `test` for its old and its new text: `app_shell_test.exs` asserts the `Calendar` label of
    `layouts.ex` through a `~w(...)` list that names neither the module nor the file. When you
    cannot tell, add the file.
- A merge of `origin/main` (AGENTS.md "Merge authority") into a branch that is not docs-only runs
  the full `mix test` before its push: the cases above pick tests from a fix commit's own files,
  not from the commits `main` brings in. A release runs it too ([workflow.md](workflow.md)
  "Releasing" step 2). A merge made only to clear a `dependency-audit` red or a `container`
  Trivy red that a fix on `main` clears ([ci.md](ci.md) "New advisory"), on a branch whose
  full `mix test` passed and with no conflict, takes a review fix commit's short run instead:
  the fence run with the test files the four cases above add for each file the merge brings in
  (`git diff --name-only HEAD...origin/main`, run before the merge), and each test file the
  branch added or changed. The cases then pick tests from what `main` brings in, and CI's full
  run on the push is the gate, as the maintainer decided on #1553 for a review fix commit.
  PR #1565 kept the full run for every merge, since the first comment on #1553 has a merge
  keep the run the repo's docs ask for; this narrows that choice. On #1510 (PR #1576) and #1581
  (PR #1592) a full run after such a merge took about 7 and 10 minutes.
- A new UI string fails `translations_complete_test` until you run
  `MIX_ENV=test mix gettext.extract --merge` and write its French msgstr in
  `priv/gettext/fr/LC_MESSAGES/default.po`. When an existing msgid is close enough, the merge
  fills the new one with that translation and flags it `#, fuzzy`. Remove the flag and rewrite
  that msgstr by hand, especially when the new msgid contains an old one: "Jellyfin web URL"
  was filled with "URL Jellyfin", the translation of "Jellyfin URL". For more than a few new
  msgids, write each with its French msgstr into a scratch `.po` and fill the catalog from it with
  `scripts/gettext-fill.exs` ([workflow.md](workflow.md) "Merge conflicts" has the command),
  which also clears the `#, fuzzy` flag on the entries it fills. The merge also flags `#, fuzzy`
  a reworded msgid close to an old one in `priv/gettext/en/LC_MESSAGES/default.po`. Leave that
  flag: every English msgstr is empty, and Gettext compiles no clause for an empty msgstr
  (`deps/gettext/lib/gettext/compiler.ex`), so the page shows the msgid. On #912 a re-check
  flagged three of them and clearing them forced a full `mix test` for a catalog change, about
  10 minutes; #948 regenerated four.
- A test sets a `:cinder` env key with `Cinder.ConfigCase.put_env/2`, which restores the old value
  on exit; `put_env/1` takes a keyword list of keys. For keys the test changes another way (a
  settings save, `Application.delete_env/2`, a raw write such as a filesystem barrier),
  `Cinder.ConfigCase.restore_env_on_exit/1` restores them by the same rule: a key unset before
  is unset after, and a set key, `nil` included, gets its old value back. For a keyword-list key,
  `Cinder.ConfigCase.put_config/2` merges the overrides and restores the same way. The household
  size band (`:tv_min_size`, `:tv_max_size`, read by `Cinder.Acquisition.HouseholdPolicy.band/1`)
  is one such key. When other test modules also read the key, as several read the band, set it
  from an `async: false` module.
- A test that a `:cinder` env key picks the module a reader calls (a `{:env, key}` health probe,
  a reader's `Application.fetch_env!/2`) sets the key, as the bullet above says, to a mock other
  than the one `config/test.exs` names, and never to the behaviour's only mock. It stubs the
  module `config/test.exs` names, when it names one, to answer otherwise. With the key on either
  of those mocks, code that skips the key and names that mock passes: `:media_info` is `nil` in
  `config/test.exs`, and `MediaInfoMock` is its one mock. When `test/test_helper.exs` defines one
  mock for the behaviour, add a second there with `Mox.defmock` and a comment naming its use.
  Before you reuse a mock, `rg` its name in `test/support` and `test/test_helper.exs`, and fix a
  docstring or comment that says no other test uses it. On #1643 (PR #1692) the new
  `Cinder.HealthTest` case stubbed `IndexerMock` only, and a `resolve/1` clause that answered
  `IndexerMock` without reading config survived it. The fix pointed the key at `InHandIndexerMock`,
  which made the docstring of `Cinder.IndexerStubs.anime_sweep_pick/4` false: a Standards finding,
  two fix commits and a re-check.
- `config/test.exs` selects `Cinder.Acquisition.IndexerMock` as the indexer source, so a grab's
  recorded source, `prowlarr` or `native`, is never the selected one. When a fetch through the
  recorded source fails with an error outside `Download.permanent_submission_errors/0`,
  `Cinder.Download.GrabFailure.guard_fetch/2` answers `{:error, :indexer_changed}` in its place,
  the client returns that, and `Cinder.Download` drops the grab with no retry. The `GrabFailure`
  moduledoc says what each kind does next. A test that makes such a fetch fail and checks
  anything but that drop (the error the client got, a retry, a strike, a search attempt, a held
  book's reason) first selects the recorded source with
  `Cinder.ConfigCase.put_env(:indexer_source, IndexerSource.Prowlarr)`, or `IndexerSource.Native`,
  as `Cinder.Download.IndexerChangeTest` "a source switch in flight" does. On #1656 the user-info
  Prowlarr case of `intent_test.exs` lost its retry this way until it selected Prowlarr.
- A test that checks what a function was called with or returned (the opts a judge got, the
  bytes `:zlib.safeInflate/2` gave back) reads them from `Cinder.CallTrace.calls/2`, whose
  moduledoc lists the traps of a hand-written `:erlang.trace`. On #1646 a hand-written trace
  failed twice: it got no message for the test process's own calls, then its pattern matched no
  function in a module that was not loaded yet.
- A test that saves settings (`Cinder.Settings.save/2`, or `put/2`, `delete/1` and `save_form/1`,
  which go through it) runs in an `async: false` module that restores every
  `Cinder.Settings.env_keys/0` key, as `Cinder.SettingsTest` does. Each save rebuilds those keys
  from the boot capture (`Cinder.Settings.Overlay.base/1`) plus the stored rows, so a `put_env/2`
  or `put_config/2` value on one of them is gone once the save returns. Seed the starting state as
  rows with the raw `save/2`, which also stores a value `save_form/1` refuses (required embedded
  subtitles with no subtitle language). Seed before creating the rows under test: a save that
  changes the anime defaults decides every anime hold again (#791).
- A test picks the media server through `Cinder.ConfigCase` too: `store_media_server_type/1`
  writes the type row without `Cinder.Settings.put/2`, which would swap the global impl off the
  Mox mock for the rest of the run. `put_plex_url/1` and `put_media_server_bootstrap/1` set
  process-global state (an OS env var, the overlay's boot capture), so only an `async: false`
  module calls them. All three restore on exit.
- Each committed movie or episode file queues a subtitle task on the one shared
  `Cinder.Subtitles.Fetcher`. `Cinder.DataCase.setup_sandbox/1`, which `DataCase` and `ConnCase`
  run, drains the Fetcher with `Cinder.DataCase.drain_subtitle_fetcher!/1` when each test ends,
  before the sandbox owner stops. A task left queued used to run inside a later test and, once
  that test turned subtitle languages on, use up its provider expectations (#685, #1028). The
  drain waits through `Cinder.LibraryStubs.await_subtitle_tasks/0`, which waits
  `Cinder.Test.DiskTask.timeout_ms()`, since a task can write its manifest through a Disk
  subprocess. `test/code_health/fetcher_wait_test.exs` fails a test that waits on the Fetcher
  with `:sys` directly.
- That drain runs after the test's own `on_exit` callbacks and after its Mox stubs are gone. So
  a test awaits its own tasks in its body with `await_subtitle_tasks/0` when an import it commits
  records sidecar languages, or when it turns subtitle languages on. Left to the drain, such a
  task calls a mock with no stub, or logs `subtitle manifest write failed ... :unsafe_destination`
  once the test has restored its library roots. In a test that is not async, the drain then
  fails the test and quotes every warning-or-above line logged while it ran (#1047). Timing
  decides whether a task is left to the drain, so such a test can pass one run and fail the next.
  An async test's drain only waits, since it can run another async test's task. Put the call
  inside the `capture_log/1` whose output the test asserts: the Fetcher's task does the logging.
- A child process inherits the suite's own priority, and that priority differs by route. On the
  dev host, `nix develop -c mix test` runs at nice 16, the idle I/O class and `SCHED_IDLE`
  (ananicy-cpp's `nix` rule). CI runs at nice 0 and the default class. A test of a subprocess's
  niceness or I/O class compares it with the suite's own. That check proves little at nice 16
  and the idle class, since nice stops at 19 and the class is already idle, so the test also
  pins the exact command line with `Cinder.Test.PriorityShims`' recording shims on `PATH`, as
  `Cinder.Library.MediaInfo.FfprobeTest` "whole-file reads" does (#862).
- `System.cmd/3` and `Port.open/2` unset a variable whose `env:` value is `""`. A test of the
  empty-value case sets it inside a `sh -c` script, such as `VAR= <cmd>` or the `:env` option
  of `Cinder.Test.ChildVM.open/4`. On #1537 a formatter mutant survived a test
  that passed `""` through a port's `env:`.
- A list built from a directory listing (`File.ls/1`, `Cinder.Library.PathPolicy.walk/2`,
  `Cinder.Library.Filesystem`'s `find_files/1`, so `Cinder.Library.Sidecars.files/1` too) comes
  in the order the disk returns. That is creation order on the btrfs dev host and can be any
  order on CI, so neither a local nor a CI pass proves a test ignores it. A test compares such a
  list sorted unless the code under test sorts it (#919).
- A test that shrinks a deadline so a call waits it out (`:walk_timeout_ms`,
  `:adoption_scan_timeout_ms`, `:health_probe_timeout_ms`, a `timeout_ms:` option) runs only that
  call under the shrunk value. A health sweep runs many probes in one call, and an adoption scan
  walks every library root in one, so shrink only the hung probe's or root's deadline with a map:
  `%{"indexer" => 200}` (`Cinder.Health` moduledoc), or `%{wedged_root => 300}` keyed by the
  root's expanded path (`scan_timeout_ms/1` in `Cinder.Library.Adoption`). Every call meant to
  finish gets a deadline with headroom for a loaded host: 10 s, as `SafeWalkTest` sets it, or 30
  s in `Cinder.Library.BoundedWalkTest`, whose waits on a guard meant to answer get 20 s in all
  (`run/3`'s `:call_timeout_ms`, `:sys.get_state/2`). A comment calls such a deadline headroom,
  since no run shows that a host cannot miss it. On #1509 (PR #1583) a Standards review flagged
  "a deadline a loaded host cannot miss", copied from this bullet into a test comment, as a
  claim no run backs: a fix commit and a re-check. A refusal meant to come at once runs under
  that same deadline, with an `elapsed` assert below half of it (1 s and 10 s), so a refusal
  that waited the deadline out fails it. On #1118 a healthy library root ran under the same 300
  ms as the wedged one, missed it on the loaded runner and turned `main` red: 43 minutes from
  the red run to the fix's merge. On #1512, in full local runs at load 60 to 64 on 16 CPUs,
  `BoundedWalkTest` missed its old 10 s deadline once and its guards' 5 s defaults three times.
- A task that a shrunk deadline kills can die before its stub runs, since a loaded runner can
  start it past the deadline. A test that reads that stub's report (its pid, a message) passes
  without it. `Cinder.HTTPPolicyTest` proves the kill through the pid a telemetry event gives it,
  so it reads the report with `after 0` ([ci.md](ci.md) "Wall-clock tests"). A test whose only
  way to the task is that report waits long enough that a stub the code left alive still
  reports: 1 s, as `Cinder.HealthTest` "a map budget kills only the probe it names, and a probe it
  omits outlasts that budget" waits. An `after 0` returns before a report still on its way.
  On #1123, with each probe started 300 ms late, an `assert_received` of the killed probe's pid
  failed, and a helper process that waited for that pid without a bound held a healthy probe until
  its 15 s budget ran out.
- A probe meant to answer after its deadline answers on a signal the test sends only after 10 s
  with the probe still alive, never after a sleep or a loop that spins until a clock time: a
  caller that wakes late reads a reply that came after the deadline. Every probe the test holds
  back meanwhile gets a budget longer than the test can hold it. `Cinder.HealthTest` "a probe
  that answers past its budget times out even behind a slower probe" does this with a helper
  process that releases each probe. On #1123 a probe that slept 500 ms against its 200 ms budget
  read `:ok` with the caller woken 400 ms late. The cases in this bullet and the one above took a
  review and two re-check rounds, about 47 minutes from the first finding to the last fix.
  `test/code_health/req_stub_sleep_test.exs` fails a sleep in a `Req.Test` stub's `fn`, also
  through `Cinder.NewznabFixtures.route/1`; its header names forms it skips, such as a spin loop.
- A test that a request ends at its `receive_timeout` sends it to `Cinder.Test.SilentServer`, a
  127.0.0.1 socket that never answers, through `req_options` that set `retry: false` and no
  plug. The `Req.Test` plug never applies `receive_timeout`: a stub that answered 500 ms late
  under a 100 ms `receive_timeout` still returned `{:ok, _}`. Req's default retry turned a
  100 ms timeout against the socket into 7.4 s. PR #1428 (for #1414) added the helper for
  `prowlarr_deadline_test.exs` and `libre_translate_test.exs`. Their match on
  `%Req.TransportError{reason: :timeout}` is the check: `bounded_request/2`'s 60 s deadline ends
  the call on `{:error, :request_timeout}` instead. Their elapsed bound is 30 s, well under that
  deadline: a 5.2 s bound failed on the CI runner, where `libre_translate_test.exs`'s call with
  a 200 ms `receive_timeout` took up to 15.3 s (#1443).
- A `plug:` stub, including `Req.Test`'s, never sees a body that `Plug.Parsers` refuses. Req's
  `run_plug` step parses the body before the stub runs, with parser options it builds itself
  (`deps/req/lib/req/steps.ex`), so no stub can raise the limit. On a POST, PUT, PATCH or DELETE
  these bodies raise `Plug.Parsers.RequestTooLargeError`: a JSON body (`application/json` or
  `+json`) over 8,000,000 bytes, a urlencoded one over 1,000,000, and a `multipart/form-data` or
  `multipart/mixed` one whose parts pass 8,000,000 bytes. Plug adds an estimate of each part's
  headers to that count, so one 7,999,900-byte part that Req's `form_multipart` builds already
  fails. A part with no filename that holds non-UTF-8 bytes can raise
  `Plug.Parsers.BadEncodingError` instead: Plug checks the bytes it read before the limit.
  `Cinder.HTTPPolicy.bounded_request/2,3` returns either error as
  `{:error, {exception, stacktrace}}`, and a bare `Req` call raises it.
  A body of any other content type or method reaches the stub whole: `Req.Test.raw_body/1`
  returns all of it, while `Plug.Conn.read_body/1` stops at 8,000,000 bytes with `{:more, ...}`.
  A test of a size cap above its body's limit takes one of two routes. It ends before the upload,
  as `qbittorrent_test.exs` "add/1 fetches a torrent of exactly the 10 MiB cap and goes on to log
  in" ends at a refused login. Or it answers the upload with a Req `:adapter` function, which
  reads `request.body` unparsed, as `sabnzbd_test.exs` "add/1 fetches an NZB of exactly the
  20 MiB cap and posts all of it to SABnzbd" does. Put that adapter in `req_options` without
  `plug:`: Req's `put_plug` step replaces the adapter with `run_plug` whenever `plug:` is set. On
  #1484 (for #1444) the first exact-cap test sent its upload to 127.0.0.1:1, a real port, and the
  Standards review rejected that test.
- A test that polls until a timer fires (a shrunk `ownership_timeout`, a lease, a TTL) runs
  `mix test.unchecked --repeat-until-failure 1000 <file> --only "test:test <name>"` before
  review. Each repeat runs the whole selection, so select that one test by name, as the bullet
  on selecting tests by name says. A poll that lands as the timer fires fails in a
  shape the first runs never show. On #1276 `Cinder.DataCaseOwnershipTest` passed 3 runs, then
  failed run 978 of 1000: its query reached the ownership proxy just after the proxy stopped,
  and exited `:noproc`. Its `assert_ownership_lapses/0` now counts each shape the lapse gives. From
  the re-check's report to the pushed fix took 28 minutes.
