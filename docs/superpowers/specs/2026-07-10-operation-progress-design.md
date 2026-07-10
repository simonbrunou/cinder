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

qBittorrent supplies all three per torrent (`progress`, `dlspeed`, and `eta`).
Its invalid or unknown ETA sentinel becomes `nil`. SABnzbd supplies per-slot
progress and `timeleft`, so it supplies progress and ETA only: its speed is
queue-wide and must not be presented as the speed of an individual TV grab.
Malformed values also become `nil` rather than reaching a poller or UI.

Both the movie and TV pollers already poll once every five seconds. On a
changed in-flight measurement, they persist those fields on the corresponding
movie or grab through the Catalog and broadcast the refreshed record. Movie
writes are guarded by the status read at tick start; grab writes are guarded by
`content_path IS NULL`. A completion, cancellation, or deletion racing a slow
client response therefore becomes a harmless no-op. This keeps all connected
LiveViews in sync and preserves the latest measurement across reconnects or app
restarts. Unchanged measurements cause no write or broadcast.

Three nullable fields are added to both `movies` and `grabs`:
`download_progress`, `download_speed`, and `download_eta`. Entering a new movie
download or upgrade, and leaving either active state, clears all three. This
reset is shared by ordinary transitions and the direct cancel/abort paths.
Likewise, the TV create, completion, retry/error, and removal paths cannot
leave an old measurement visible. A partial or failed client observation clears
the values it could not freshly report, rather than presenting yesterday's rate
or ETA as live.

## Rendering

Extend the existing `status_badge` component with optional progress, speed, and
ETA inputs. Existing callers without these inputs keep the current compact
badge. Its expanded operation branch uses a flexible layout rather than trying
to fit a progress bar inside the existing small badge container.

- `:searching` renders a labelled searching indeterminate indicator.
- A movie at `:downloaded` and a TV grab with a `content_path` render a labelled
  **Importing** indeterminate indicator. They are awaiting import, not
  terminally downloaded.
- `:downloading` and a downloading `:upgrading` movie render a native
  `<progress>` element with visible percentage, formatted byte rate, and ETA.
- If a client cannot provide speed or ETA, omit only that value; never invent a
  zero or an ETA.
- Terminal, queued, request, approval, and failure badges retain their current
  labels and colours.

An upgrade has no durable post-download import state today: the replacement
import is synchronous while its movie remains `:upgrading`. Do not add a
speculative state solely for this display; show the determinate upgrade progress
while the client supplies it.

The expanded movie operation component receives the full movie record at Movie
Detail, Activity, Library, Dashboard, and My Requests. My Requests keeps its
request-status badge and replaces its local status-only movie map with a
`tmdb_id => movie` map for the second, operation badge. The global
`movie_status_map/0` remains unchanged for Discover. Activity's TV grab display
reloads the fresh grab after its existing series-topic broadcast.

No browser polling, custom JavaScript, or UI dependency is added. The existing
five-second poll and PubSub updates are the only update mechanism.

## Error handling

Client errors retain current retry and park behaviour. A partial status response
is valid: progress can render without speed or ETA. Clearing the metrics during
pipeline transitions prevents stale values after an error or completed import.

## Tests

- qBittorrent and SABnzbd client tests prove speed and ETA normalization.
- Movie and TV poller tests prove changed metrics persist and broadcast, while
  unchanged metrics do not write; they also cover a completion/deletion racing
  the client response.
- Catalog tests prove every transition, cancellation, abort, retry, and grab
  completion/error path clears obsolete metrics.
- Client tests cover qBittorrent's unknown ETA sentinel, SABnzbd's per-slot ETA
  parsing, and SABnzbd's intentionally absent per-grab speed.
- LiveView tests cover the determinate download display, indeterminate search
  and import display, and every existing movie/grab operation-badge location,
  including My Requests' full-movie lookup.
- `mix test` remains the final gate.
