# Code navigation

## Graphify: source under `lib/` and `test/`

`graphify-out/` holds a local knowledge graph. It is gitignored; regenerate it with
`graphify update .`.

- For a question about source under `lib/` or `test/`, first run `graphify query "<question>"`
  when `graphify-out/graph.json` exists. Use `graphify path "<A>" "<B>"` for relationships and
  `graphify explain "<concept>"` for one concept.
- For an exact code pattern, such as the `Repo` write-site search in
  [architecture.md](architecture.md), search the files directly. The graph answers concept and
  relationship questions, not exhaustive pattern matches.
- The graph does not cover `deps/`, `_build/`, `config/`, `mix.exs` or tooling/config files.
  Read those directly.
- Read `graphify-out/GRAPH_REPORT.md` only for a broad architecture review, or when a scoped
  query does not surface enough context.
- After modifying project source, run `graphify update .`.

## Tidewave: the running dev app

While the dev server runs, the Tidewave MCP is available. Use it (`project_eval`,
`get_ecto_schemas`, `execute_sql_query`, `get_logs`) to inspect the running app instead of
guessing.
