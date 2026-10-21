# Contributing to Cinder

Cinder is licensed **GPL-3.0-or-later** (`SPDX-License-Identifier: GPL-3.0-or-later`). By
contributing you agree your contributions are licensed under the same terms.

## Development setup

```sh
mix setup        # deps + create/migrate/seed the dev DB + build assets
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
- **Status and derived-state writes go through the context choke-points**
  (`Catalog.MovieLifecycle` / `Catalog.transition_episode`) so SQLite WAL + `busy_timeout` stays
  correct under a racing poller.
- New behaviour ⇒ a test. New service config ⇒ **not** a new env var: add a setting definition to
  `Cinder.Settings.Registry` instead (config is in-app, overlaid on env bootstrap).
- A `Book*` module serves the whole book family (e-books and audiobooks, see `GLOSSARY.md`). A
  module for one kind alone is named `Ebook*` or `Audiobook*`; `test/code_health_test.exs` fails
  on a `Book*` module that has an `Audiobook*` sibling.
- Keep diffs minimal and trace each change to the request; `credo --strict` and warnings-as-errors
  must stay clean.
- A user-visible change adds a changelog fragment, `changelog.d/<number>-<slug>.md` (format in
  [`changelog.d/README.md`](changelog.d/README.md)), instead of an entry under `[Unreleased]` in
  `CHANGELOG.md`, so two PRs never conflict on the changelog. `test/code_health_test.exs` fails
  on a new entry under `[Unreleased]` and on a fragment a release could not fold.

See [`docs/agents/architecture.md`](docs/agents/architecture.md) for fuller architecture notes
and [`ROADMAP.md`](ROADMAP.md) for historical scope.

### Agent configuration

`AGENTS.md` is the shared instruction source; it links topic docs under `docs/agents/`.
Project-specific workflows live as portable Agent Skills under `.agents/skills/`; dependency
guidance is synced directly with
`mix usage_rules.sync AGENTS.md --all --link-to-folder deps --remove-missing`. Client-specific
files are thin adapters only: `.mcp.json` and `.codex/config.toml` connect Tidewave, while
`CLAUDE.md` links to `AGENTS.md` for compatibility. Non-trivial feature work is planned as Forgejo
issues with Matt Pocock's skills (`/to-spec`, `/to-tickets`; see `docs/agents/workflow.md`).
`specs/NNN-slug/` is the frozen record of the features planned earlier with Spec Kit.

## Branches & PRs

Work one focused change per branch off `main`, keep `mix test` green, and open a PR on Forgejo
(`origin`, git.sbrn.eu/simonbrunou/cinder). GitHub is a push mirror of Forgejo, so PRs and issues
go to Forgejo only.

`main` is protected: a PR merges once the three jobs in `.forgejo/workflows/ci.yml` pass on it
(`test`, `container`, `dependency-audit`). Renovate (`renovate.json`) opens the dependency-update
PRs.

## Releasing (maintainers)

1. On a branch synced with `main`, bump `@version` in `mix.exs`, then run
   `mix cinder.changelog.release`. It folds the fragments in `changelog.d/` and the entries left
   under `[Unreleased]` into a dated `CHANGELOG.md` section, updates the compare links, and
   deletes the fragments. Add a release introduction under the new heading by hand if the release
   needs one. The first release after #843 also deletes `@legacy_unreleased_sha256` and the
   `or hash == ...` clause that reads it in `test/code_health_test.exs`.
2. Land it on a **green** `main` right away. Before tagging, check that `changelog.d/` holds only
   `README.md`; move a fragment that merged after the fold into the new section by hand.
3. Once CI is green on the merge commit, tag that commit and push the tag:
   `git tag -a v0.7.0 <merge sha> -m "Cinder 0.7.0" && git push origin v0.7.0` (the tag is `v` +
   the mix.exs version).
4. The [`release`](.github/workflows/release.yml) workflow builds the image and pushes
   `ghcr.io/simonbrunou/cinder` tagged `:0.7.0`, `:0.7`, and `:latest`. Check the result with
   `scripts/verify-ghcr-release.sh 0.7.0`.
5. **First release only:** GHCR packages are **private by default**. After the first successful
   push, open the package settings at
   `https://github.com/users/simonbrunou/packages/container/cinder/settings`, set **visibility →
   Public**, and confirm it's linked to the repo (the image carries the
   `org.opencontainers.image.source` label, which links it automatically). Until it's public,
   `docker compose up` can't *pull* the published image — it still builds locally via `build: .`.
