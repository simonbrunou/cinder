# Operation progress design

## Goal

Replace vague in-flight download badges with live operation progress across the
movie and TV pipelines. Downloading shows a percentage, current speed, and ETA;
searching and importing show their named, indeterminate phase.

## Scope

- Movies: render operation progress wherever the movie pipeline badge already
  appears: movie detail, Activity, Library, Dashboard, and My Requests.
- TV: render the same download progress for the in-flight grab badge on
  Activity.
- Request, approval, episode, health, and monitoring badges remain unchanged:
  they describe a different state, not a running download.

## Data flow

The existing download clients normalize their status response to include:

- `progress`: a `0.0..1.0` fraction;
- `speed`: integer bytes per second, when supplied by the client;
- `eta`: integer seconds remaining, when supplied by the client.

Both the movie and TV pollers already poll once every five seconds. On a
changed in-flight measurement, they persist those fields on the corresponding
movie or grab through the Catalog and broadcast the refreshed record. This
keeps all connected LiveViews in sync and preserves the latest measurement
across reconnects or app restarts. Unchanged measurements cause no write or
broadcast.

Three nullable fields are added to both `movies` and `grabs`:
`download_progress`, `download_speed`, and `download_eta`. Pipeline transitions
clear them when an item enters a new download or leaves download activity, so
old values never appear on a subsequent request, import, failure, cancellation,
or upgrade.

## Rendering

Extend the existing `status_badge` component with optional progress, speed, and
ETA inputs. Existing callers without these inputs keep the current compact
badge.

- `:searching` and the movie/TV post-download import state render a labelled
  indeterminate indicator.
- `:downloading` and a downloading `:upgrading` movie render a native
  `<progress>` element with visible percentage, formatted byte rate, and ETA.
- If a client cannot provide speed or ETA, omit only that value; never invent a
  zero or an ETA.
- Terminal, queued, request, approval, and failure badges retain their current
  labels and colours.

No browser polling, custom JavaScript, or UI dependency is added. The existing
five-second poll and PubSub updates are the only update mechanism.

## Error handling

Client errors retain current retry and park behaviour. A partial status response
is valid: progress can render without speed or ETA. Clearing the metrics during
pipeline transitions prevents stale values after an error or completed import.

## Tests

- qBittorrent and SABnzbd client tests prove speed and ETA normalization.
- Movie and TV poller tests prove changed metrics persist and broadcast, while
  unchanged metrics do not write.
- Catalog tests prove transitions clear obsolete metrics.
- LiveView tests cover the determinate download display, indeterminate search
  and import display, and every existing movie/grab operation-badge location.
- `mix test` remains the final gate.
