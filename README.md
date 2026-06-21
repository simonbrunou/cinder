# Cinder

[![CI](https://github.com/simonbrunou/cinder/actions/workflows/ci.yml/badge.svg)](https://github.com/simonbrunou/cinder/actions/workflows/ci.yml)

A single-household, self-hosted replacement for the Sonarr / Radarr / Seerr loop:
request a movie → find the best release → download it → import it into Jellyfin/Plex.
Built on Phoenix/LiveView with SQLite; everything external (TMDB, Prowlarr,
qBittorrent/SABnzbd, Jellyfin/Plex) sits behind a behaviour so it can be mocked.

The movies vertical slice is built and validated live. Current work is **Part II —
from slice to v1.0** (movies + TV + multi-user, public self-host). See `ROADMAP.md`.

## Development

```sh
mix setup        # install deps, create + migrate the DB, build assets
mix phx.server   # then visit http://localhost:4000
mix test         # compile (warnings-as-errors) + format check + credo --strict + suite
```

License: GPL-3.0 (see `LICENSE`).
