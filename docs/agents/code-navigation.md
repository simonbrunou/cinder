# Code navigation

## Callers and dependents: source under `lib/` and `test/`

- Search text with `rg -n '<pattern>' lib test`. It is the only one of these tools that reads
  `_test.exs` files and finds an exact code pattern, such as the `Repo` write-site search in
  [architecture.md](architecture.md).
- `mix xref` covers the modules under `lib/` and `test/support/`, never a `_test.exs` file. Run
  it as `MIX_ENV=test mix xref ...` in a seeded worktree ([workflow.md](workflow.md)
  "Worktrees").
  - `mix xref callers <Module>` prints each other file that references the module, with the kind
    of reference (compile, export or runtime). It never lists the module's own file. It takes a
    module only: `Mod.fun/arity` exits 1 with `expects a MODULE`. A misspelled module prints
    nothing and exits 0.
  - `mix xref trace <file>` compiles the file and prints each reference it makes to Cinder's
    modules, with its line, such as `call Cinder.Requests.create_request/2 (runtime)`. It leaves
    out calls to dependencies, to Elixir itself and local calls written without a module name. On
    a `_test.exs` file it exits 1 with
    `cannot use ExUnit.Case without starting the ExUnit application`.
  - To find a function's call sites, run `trace` on each file `callers` printed and filter with
    `rg -F 'Cinder.Requests.create_request/'`, which keeps every arity. Then search the
    defining module's own file with `rg -n 'create_request\(' lib/cinder/requests.ex`: for
    `approve_request/3` the `trace` recipe found 4 call sites and missed the local one in
    `requests.ex`.
  - `mix xref graph --sink <file> --only-nodes` prints every file that depends on the file,
    directly or through other files. Through runtime calls that can reach most of `lib/`; for
    direct references use `callers`.

## Tidewave: the running dev app

While the dev server runs, the Tidewave MCP is available. Use it (`project_eval`,
`get_ecto_schemas`, `execute_sql_query`, `get_logs`) to inspect the running app instead of
guessing.

A page with data needs the dev seed first:
`mix run priv/repo/seeds.exs && PORT=4123 mix phx.server` (an admin whose login it prints, setup
marked complete, one TV grab with an undecided file on `/activity`; `mix ecto.setup` runs it on a
new database).

To check the movie page's manual-search panel with results, a search report or an error you
choose, serve the dev app with `scripts/dev-manual-search.exs` instead: it answers with a fake
indexer source, and its header gives the command, the login and the movies to open.

To run a native search over real HTTP for a native-indexer PR's test path, run
`scripts/dev-native-search.exs`: it serves a Newznab and Torznab listener on 127.0.0.1, creates
dev indexers on it, among them a limited, a rejected and a flaky one, and prints what the
searches found, each dev indexer's backoff state and each request line, as its header says. On
#1653 (PR #1755) that test path took a hand-written Python listener and a second script.

To serve the dev app with indexer definitions you wrote, apply them and serve from one script,
`PHX_SERVER=true PORT=4123 mix run --no-halt <script>`. Stop the definitions updater on the
script's first line, with `Supervisor.terminate_child/2` on `Cinder.PollerSupervisor` and
`Cinder.Indexers.Definitions.Updater`. At boot the updater fetches the definitions from GitHub
and tries to apply them over your set, so a separate `mix phx.server` boot can replace it.
`Cinder.Indexers.Definitions.apply_set/2` refuses a set the shrink guard rejects, as step 2 of
that module's moduledoc says. After that refusal, `accept_smaller_set(set.commit)` of the same
module lets the same `%Set{}` pass the guard. On #1675 (PR #1861) the updater replaced the test
set once, and the script then applied 2,500 filler files to pass the guard.
