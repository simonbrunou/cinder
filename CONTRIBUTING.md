# Contributing to Cinder

Cinder is licensed **GPL-3.0-or-later** (`SPDX-License-Identifier: GPL-3.0-or-later`). By
contributing you agree your contributions are licensed under the same terms.

## Development setup

```sh
mix setup        # deps + create/migrate DB + build assets
mix phx.server   # run the app at http://localhost:4000
```

`mix test` is the **source of truth** and the only "is it green" gate. The alias runs, in order:
`compile --warnings-as-errors`, `format --check-formatted`, `credo --strict`, then the suite. Run
it before every commit; CI runs the same thing on every push and PR.

In dev the [Tidewave](https://hexdocs.pm/tidewave) MCP is wired (`/tidewave/mcp`) — prefer it for
inspecting the running app over guessing.

## Conventions

- **External services only through behaviours** (`Cinder.Catalog.TMDB`,
  `Cinder.Acquisition.Indexer`, `Cinder.Download.Client`, `Cinder.Library.MediaServer`), resolved
  from config at runtime and mocked with **Mox** in tests. **Tests never hit the network or a real
  service.**
- **Every state change goes through the context choke-point** (`Catalog.transition` /
  `transition_episode`) so SQLite WAL + `busy_timeout` stays correct under a racing poller.
- New behaviour ⇒ a test. New service config ⇒ **not** a new env var: add a `Cinder.Settings`
  registry entry instead (config is in-app, overlaid on env bootstrap).
- Keep diffs minimal and trace each change to the request; `credo --strict` and warnings-as-errors
  must stay clean.

See [`CLAUDE.md`](CLAUDE.md) for fuller architecture notes and [`ROADMAP.md`](ROADMAP.md) for
current scope.

## Branches & PRs

Work one focused change per branch off `main`, keep `mix test` green, and open a PR. `main` is
guarded by CI (compile/format/credo/test on every push + PR).

## Releasing (maintainers)

1. Bump `version:` in `mix.exs` and add a dated section to `CHANGELOG.md`.
2. Land it on a **green** `main`.
3. Tag and push: `git tag v0.7.0 && git push origin v0.7.0` (the tag is `v` + the mix.exs version).
4. The [`release`](.github/workflows/release.yml) workflow builds the image and pushes
   `ghcr.io/simonbrunou/cinder` tagged `:0.7.0`, `:0.7`, and `:latest`.
5. **First release only:** GHCR packages are **private by default**. After the first successful
   push, open the package settings at
   `https://github.com/users/simonbrunou/packages/container/cinder/settings`, set **visibility →
   Public**, and confirm it's linked to the repo (the image carries the
   `org.opencontainers.image.source` label, which links it automatically). Until it's public,
   `docker compose up` can't *pull* the published image — it still builds locally via `build: .`.
