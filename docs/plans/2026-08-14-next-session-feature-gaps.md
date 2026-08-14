# Next session: remaining feature gaps

Council review: n/a — short next-session handoff, not an implementation plan.

**Status:** implemented on 2026-08-14.

## Completed

Added automatic upgrades for Anime TV series through the existing Anime search, reservation,
verification, and import paths.

The smallest complete version should reuse the existing Anime search, reservation, verification,
and import paths. It must respect the TV upgrade cutoff, never downgrade a file, and retain the
current file until a replacement has been verified and committed.

## Verified

- [x] An eligible Anime series is searched and upgraded automatically.
- [x] A series at its configured cutoff is skipped.
- [x] A failed or ambiguous replacement leaves the existing episode files available.
- [x] Standard TV upgrade behavior is unchanged.
- [x] `mix test` passes.

## Deferred until there is a concrete household need

- Plex watchlist sync for TV seasons (movie sync already exists).
- Arbitrary named library destinations beyond Standard and Anime.
- Built-in backup scheduling and restore verification; the operating guide already documents safe
  SQLite backups.
- Additional download clients beyond qBittorrent and SABnzbd.
- Torrent ratio/seed-time cleanup and BitTorrent v2/hybrid support.

Do not bundle the deferred items into the Anime upgrade PR.
