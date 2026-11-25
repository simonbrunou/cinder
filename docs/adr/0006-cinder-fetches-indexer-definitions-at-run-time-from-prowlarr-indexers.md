# Cinder fetches indexer definitions at run time from Prowlarr/Indexers

Cinder's Cardigann engine (ADR 0005) needs indexer definitions, and they go stale fast: Jackett
made about 162 definition commits a month over the last year, 39 of a sample of 100 answer a site
change, and Torrent9 moved domain 6 times (#1611). Prod deploys `main` on every merge, but another
install runs whatever image or clone its admin last pulled, and the public image is published only
from a `v*` tag (`docs/agents/workflow.md` "Releasing"), the last one cut on 2026-09-05. So each
install downloads the definitions itself, at boot and every 24 hours, from the Prowlarr/Indexers
repository on GitHub, pinned to one commit. Neither Cinder's image nor its repository ships an
upstream definition. The engine's tests use definitions written for Cinder, and only the parity
check on prod (#1624) reads the real files, fetched when it runs (#1616).

## Considered options

- A seed bundled in the image, refreshed at run time. A fresh install would work offline, but
  Cinder would distribute files that are GPL-2.0 or carry no licence grant at all (583 of the 584
  come from Jackett). Bundling rests on a "mere aggregation" reading no lawyer has checked (#1611).
- Prowlarr's own server, `indexers.prowlarr.com`, which picks each file's schema version itself.
  It is Prowlarr's infrastructure for Prowlarr installs, and #1611 found no terms of use for it in
  the Prowlarr GitHub org. It serves no older commit, so a set cannot be pinned (#1616).
- Jackett's repository, which keeps its licence file beside the definitions. Run-time fetching
  already leaves Cinder distributing none. Jackett has no schema versions, so a change that needs
  a newer engine arrives with nothing to hold it back. It also lacks Prowlarr's edits, while the
  parity check compares Cinder against Prowlarr.
- A snapshot the Cinder maintainer reviews before every household gets it, or the admin's
  approval of every update. Each site fix would wait for that review, and 469 of the 584
  definitions changed in a year. Holding every update of an indexer that has credentials was not
  needed: the credential-host rule below covers what that hold would guard.
- A wait of 24 to 48 hours before an update reaches a public indexer, to let upstream revert a
  bad change first. Every site fix would land a day later than in Prowlarr.

## Consequences

- Updates apply with no human review, so the definitions stay untrusted input (ADR 0005). Each
  indexer runs the last version of its definition that loaded cleanly. A newer version that fails
  to load, uses an unbuilt feature, needs a newer Cinder, or, for an indexer with credentials,
  would send them to a new host or trust other certificates waits as a held definition update.
  An indexer has credentials once any of its text or password settings holds a value.
- A secret setting's value only ever goes to the indexer's credential hosts: its stored base URL
  and every full URL the definition names, filled in with the stored settings. Credentials appear
  in more places than `links` and the login path, such as `download.before` inputs and an API URL
  taken from a setting's default.
- A definition is keyed by its file name, as Prowlarr's `DefinitionFile` is, because 5 files have
  an `id` that differs from it.
- Prowlarr's sync puts a changed file that fails the current schema in the folder of a newer
  schema version, and keeps the older version of the file below. Cinder reads the folders from
  `MIN_VERSION` up to the schema version its engine declares. A configured indexer whose file has
  a newer version in a folder above that holds it as needing a newer Cinder.
- The commit comes from `info/refs`, not GitHub's REST API, whose unauthenticated limit of 60 calls
  an hour per IP also counts a 304 answer. Codeload serves the commit as a tar.gz or a zip. Cinder
  takes the zip and reads it with a streaming reader with entry and size caps, on the pattern of
  its own `BookArchive.Zip`. OTP's `:erl_tar` is no such reader: its `:memory` extraction inflates
  each entry whole and passes a `..` path through.
- An install that cannot reach GitHub has no Cardigann indexer until a fetch succeeds. Newznab and
  Torznab indexers need no definition.
