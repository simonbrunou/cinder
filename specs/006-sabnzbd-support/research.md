# SABnzbd support — design

**Status:** approved, pre-implementation
**Date:** 2026-06-19
**Council review: 2 rounds — consensus sound to implement. Residuals (all LOW, non-blocking): verify `nzo_ids`-on-history against the real SABnzbd in the Phase-5 live smoke test; `:no_client → :import_failed` reuses the existing terminal label by design. Round-1 "scorer picks 4K every time" was a misread (resolution-rank sorts first) — corrected.**
**Context:** `Cinder.Download` (+ small touches in `Cinder.Acquisition` and `Cinder.Catalog`)

## Goal

Add SABnzbd (Usenet) as a download client that runs **alongside** the existing
qBittorrent (torrent) client. Each release is routed to the right client by its
protocol: torrents → qBittorrent, NZBs → SABnzbd. A single Cinder instance can
download from both at once. This is the real-world Radarr-style setup where
Prowlarr aggregates both torrent and Usenet indexers.

Decisions locked during brainstorming:
- **Both clients live, routed by protocol** (not a single swappable client).
- **Scorer stays protocol-blind** — best resolution then largest size wins,
  regardless of protocol. No Usenet-vs-torrent preference. (Deferred; see Out of
  scope. The size caveat this creates is documented under "Scoring & Usenet size.")
- **Graceful degradation IS in scope** — if only one client is configured, only
  that protocol's releases are considered (configuring just `torrent:` cleanly
  yields torrent-only behaviour).
- SABnzbd `add` uses **`addurl`** (SABnzbd fetches the NZB itself) — not
  `addfile` with proxied bytes.

## Why routing touches two places, not one

Routing happens at **both** `add` time and `status` time:

- **`add` time** — `Download.start/1` picks the client from the winning
  release's protocol.
- **`status` time** — `Poller.advance/1` polls an already-downloading movie and
  must call the **same** client it added to. A `download_id` alone can't reveal
  which (a SABnzbd `nzo_id` vs a torrent infohash), so **the protocol is
  persisted on the movie** and read back at poll time.

The `Cinder.Download.Client` behaviour itself is **unchanged** — SABnzbd
implements the existing `add/1` + `status/1` contract (`lib/cinder/download/client.ex:8,17`).
All new wiring is routing around the contract, plus the new impl.

## Components

### 1. `Cinder.Acquisition.Release` — carry protocol

Add `:protocol` to the struct (`:torrent | :usenet`). Populated from the
indexer result map's `:protocol` key in `Release.new/1` (same pattern as the
other carried fields).

### 2. `Cinder.Acquisition.Indexer.Prowlarr` — emit protocol

`normalize/1` carries one more field:

```elixir
protocol: case result["protocol"] do
  "usenet" -> :usenet
  _        -> :torrent
end
```

Prowlarr's unified `/api/v1/search` returns `"protocol"` as `"torrent"` or
`"usenet"`. **Conservative default `:torrent`** for any absent/unexpected value.

**Known edge (tested, accepted):** if a Usenet indexer mis-reports or omits the
`protocol` field, its NZBs default to `:torrent`, route to qBittorrent's
`add_torrent_url/1` (`qbittorrent.ex:42`), fail `Torrent.infohash/1` with
`:bad_torrent`, and the movie parks **terminally** at `:search_failed`
(`poller.ex:90,100`). This is a loud, non-corrupting failure, and Prowlarr sets
`protocol` reliably, so we keep the default — but a test asserts an `.nzb` URL
with a missing protocol field is parsed as `:torrent` (documenting the behaviour)
so the edge is visible, not surprising.

### 3. `Cinder.Acquisition` — protocol availability filter (graceful degradation)

The §"graceful degradation" guard lives in **`Acquisition.best_release/2`**, NOT
in the Scorer. `best_release/2` already maps raw results → `%Release{}` before
scoring (`acquisition.ex:21-23`); it gains a protocol filter *before*
`Scorer.select`:

```elixir
def best_release(imdb_id, opts \\ []) do
  allowed = Keyword.get(opts, :protocols)            # nil => allow all (back-compat)
  case indexer().search(imdb_id) do
    {:ok, raw} ->
      raw
      |> Enum.map(&Release.new/1)
      |> filter_protocols(allowed)                   # drop releases with no configured client
      |> Scorer.select(opts)
    {:error, _} = err -> err
  end
end
```

**The Scorer is untouched** — its single responsibility (size band, blocklist,
resolution ranking) stays clean, per ROADMAP Phase 2's "explicit, configurable
rules." Protocol availability is a download-client capability concern, so it sits
at the acquisition boundary that `Download.start/1` already drives, not inside the
quality scorer. `Download.start/1` passes `protocols: Download.available_protocols()`.

### 4. `Cinder.Catalog.Movie` — persist the protocol

New field: `download_protocol`, `Ecto.Enum, values: [:torrent, :usenet]`,
**nullable, no default**.

- Migration body (use the **download-fields** migration as the template —
  `20260618194259_add_download_fields_to_movies.exs` — NOT the
  `null: false, default:` search-attempts one):
  ```elixir
  alter table(:movies) do
    add :download_protocol, :string   # backed by Ecto.Enum; nullable, no default, no backfill
  end
  ```
- Add `:download_protocol` to **`transition_changeset/1`'s cast list**
  (`movie.ex:51-58`). If this step is missed the failure is *silent* (Ecto drops
  un-cast keys), so the routing test (below) must go through `Catalog.transition`
  and re-read, not fabricate a `%Movie{download_protocol: …}`.
- No backfill: rows in-flight at upgrade are all torrents (SABnzbd didn't exist
  pre-upgrade), and `client_for(nil)` resolves `:torrent`.

### 5. `Cinder.Download` — routing

- New resolvers (non-raising lookup so the poller can bound a missing client —
  see §6):

  ```elixir
  @doc "Resolves the client module for a protocol. nil => :torrent (pre-upgrade rows)."
  def client_for(protocol) do
    clients = Application.fetch_env!(:cinder, :download_clients)
    Map.fetch(clients, protocol || :torrent)        # {:ok, module} | :error
  end

  def available_protocols do
    :cinder |> Application.fetch_env!(:download_clients) |> Map.keys()
  end
  ```

- `start/1` — the **full** rewrite (the `protocols:` opt must thread through the
  existing `with`/`case`, and `download_protocol` is written **atomically with**
  `download_id` in one transition):

  ```elixir
  def start(%Movie{} = movie) do
    with {:ok, imdb_id} <- ensure_imdb_id(movie),
         {:ok, movie} <- Catalog.transition(movie, %{status: :searching, imdb_id: imdb_id}) do
      case Acquisition.best_release(imdb_id, protocols: available_protocols()) do
        {:ok, release} -> add_to_client(movie, release)
        :no_match -> Catalog.transition(movie, %{status: :no_match})
        {:error, _} = err -> err
      end
    else
      :no_imdb_id -> {:error, :no_imdb_id}
      {:error, _} = err -> err
    end
  end

  defp add_to_client(movie, release) do
    with {:ok, client} <- client_for(release.protocol),
         {:ok, download_id} <- client.add(release) do
      # download_id and download_protocol MUST be written in the same transition:
      # a torn write (id set, protocol nil) would route this download to :torrent.
      Catalog.transition(movie, %{
        status: :downloading,
        download_id: download_id,
        download_protocol: release.protocol
      })
    else
      :error -> {:error, :no_client}     # unreachable post-filter (§3); fail-loud guard
      {:error, _} = err -> err
    end
  end
  ```

  The old private `client/0` (single `:download_client` lookup) is removed.

### 6. `Cinder.Download.Poller` — route status by stored protocol, bounded

`advance/1` resolves the client from the movie's persisted protocol via the
**non-raising** `client_for/1`, and **bounds the missing-client case** so it
can't hang. (Without this, a `Map.fetch!` raise would be swallowed by
`isolate/2` (`poller.ex:194-198`), leaving the movie at `:downloading` and
re-raising every tick forever — never reaching `retry_or_fail`, never terminal.)

```elixir
defp advance(movie) do
  case Cinder.Download.client_for(movie.download_protocol) do
    {:ok, client} -> advance_with(movie, client)
    :error -> retry_or_fail(movie, :no_client, :import_attempts, :import_failed)
  end
end

# advance_with/2 is today's advance/1 body, unchanged, with client.status(...) in place
# of client().status(...).
```

No other poller logic changes — state machine, retry/backoff, crash recovery,
import path are identical. The `add`-time path can't hit `:error` (the §3 filter
guarantees the winner's protocol is configured); the poll-time path can (a
client removed from config mid-download), and now parks it at `:import_failed`
after the existing bound instead of hanging.

### 7. `Cinder.Download.Client.Sabnzbd` — the new impl

Implements the existing behaviour, backed by `Req`, against SABnzbd's single
JSON API endpoint (`GET /api?mode=…&apikey=…&output=json`). Reads `base_url`,
`api_key`, and optional `req_options` from
`config :cinder, Cinder.Download.Client.Sabnzbd` at runtime (mirrors the
qBittorrent impl). Default `base_url`: `http://localhost:8080`; API path `/api`;
the API key is a query param (no auth header, no stateful login — simpler than
qBittorrent's SID flow).

**Build query params with Req's `params:`** (never hand-build the query string)
so the NZB `name` URL — which itself contains `?apikey=…&id=…` — is encoded
correctly.

Requires **SABnzbd ≥ 0.8.0** (every version in the wild): `addurl` has returned a
usable, durable `nzo_id` since 0.8.0Beta3. Do **not** add an `addfile` fallback
on account of pre-0.8 forum threads — it isn't needed.

#### `add/1`

```
GET /api  params: mode=addurl, name=<release.download_url>, apikey=KEY, output=json
```

SABnzbd returns HTTP 200 with `"status": false` on failure, so success is
checked on the JSON, not the status code (analogue of qBittorrent's `"Fails."`
check — but note SABnzbd's add is **asynchronous**: `{:ok, nzo_id}` confirms the
job was *queued*, not that the NZB URL was retrievable; a bad URL surfaces later
as history `Failed`, handled by `status/1`):

- `{"status": true, "nzo_ids": [id | _]}` → `{:ok, id}` (the `nzo_id` becomes
  `download_id`).
- `{"status": true, "nzo_ids": []}` → `{:error, :add_rejected}`. **This empty
  list is SABnzbd's duplicate-rejection signal** (the add request "succeeded" but
  no job was created). Flows through `Download.start`'s `{:error, _}` path →
  bounded retry → `:search_failed`. (Retrying a duplicate stays a duplicate, so
  it terminates at the bound rather than ever succeeding — acceptable; not
  special-cased.)
- `{"status": false}` → `{:error, :add_rejected}`.

#### `status/1` — queue, then history, **always scoped by `nzo_ids`**

`nzo_id` lives in the **queue** while downloading and moves to **history** for
post-processing and completion. Check queue first, then history. **Both calls
MUST pass `nzo_ids=<download_id>`** — otherwise SABnzbd's default queue/history
page limit can hide the job behind pagination and `status/1` would wrongly return
`:not_found`, failing a healthy download:

```
GET /api  params: mode=queue,   nzo_ids=<id>, output=json, apikey=KEY
GET /api  params: mode=history, nzo_ids=<id>, output=json, apikey=KEY
```

(`nzo_ids` filtering on the **history** endpoint is reliable on every maintained
SABnzbd, 2.x–4.x; it was the last of these params to land historically, so the
Phase-5 live smoke test should confirm a completed job is found by id on the real
instance — the roadmap already mandates that live run.)

State mapping (the SABnzbd analogue of the qBittorrent state table):

| Where the nzo_id is found | SABnzbd status | → behaviour `state` | `content_path` |
|---|---|---|---|
| queue slot | any (`Downloading`, `Queued`, `Paused`, `Fetching`, `Propagating`, …) | `:downloading` | — |
| history slot | `Completed` | `:completed` | slot `storage` |
| history slot | `Failed` | `:error` | — |
| history slot | post-processing (`Verifying`, `Repairing`, `Extracting`, `Moving`, `Running`, `QuickCheck`, `Queued`, …) | `:downloading` | — |
| not in queue or history | — | `{:error, :not_found}` | — |

- `progress`: queue slot `percentage` is a **string** (e.g. `"42"`) — coerce
  (`Integer.parse`/`Float.parse`) before `/ 100`; a raw `"42" / 100` raises.
  Anything in history → `1.0`. (Progress is cosmetic — the poller advances on
  `state`, not `progress` — but an unhandled raise here would be swallowed by the
  poller's `isolate/2` and silently skip the movie that tick, so coerce defensively.)
- The post-processing window mapping to `:downloading` mirrors qBittorrent's
  `moving` → `:downloading` (`qbittorrent.ex:171`): finished downloading but the
  final path isn't settled. The poller already refuses to advance a `:completed`
  download with a blank `content_path` (`poller.ex:125-133`), so a `Completed`
  slot whose `storage` is momentarily empty is held safely.
- `storage` is SABnzbd's **final completed folder** (video + par2 + nfo), not a
  single file — reliably populated when `status == Completed`. The import path
  handles a directory `content_path` already (see "Import path" below).

**`:not_found` caveat (document in the SABnzbd setup notes):** if the user runs
SABnzbd with **"Pause on Duplicates" / abort-on-duplicate**, the `nzo_id`
returned by `addurl` is *replaced* when the job materializes, so the persisted
`download_id` never appears in queue or history → a **permanent** `:not_found`
(not the transient "job between queue and history" blip the bounded retry
absorbs). The remediation is a config requirement, not code: **disable
duplicate-pause in SABnzbd** (or set it to a non-id-changing mode). The
`:not_found` → bounded retry → `:import_failed` path still fails safely; it just
mislabels the cause. Documented in §8 setup notes.

### 8. Config

`config/config.exs` — swap the single key for a protocol→module map:

```elixir
# was: config :cinder, download_client: Cinder.Download.Client.QBittorrent
config :cinder, download_clients: %{
  torrent: Cinder.Download.Client.QBittorrent,
  usenet:  Cinder.Download.Client.Sabnzbd
}
```

**Tradeoff acknowledged:** this is a breaking config change (vs. an additive
`:usenet_client` key that would preserve back-compat). The map is chosen because
it's the clearer long-term shape and Cinder is pre-1.0/single-household; the
churn is four known sites (`config.exs`, `test.exs`, the removed `client/0` in
`download.ex` + `poller.ex`). To run **one** client only, drop the other key from
the map — `available_protocols/0` then reports only the configured protocol and
the §3 filter excludes the rest.

`config/runtime.exs` — a SABnzbd block mirroring the qBittorrent one:

```elixir
if url = System.get_env("SABNZBD_URL") do
  config :cinder, Cinder.Download.Client.Sabnzbd,
    base_url: url,
    api_key: System.get_env("SABNZBD_API_KEY")
end
```

`config/test.exs` — map **both** protocols to the existing
`Cinder.Download.ClientMock`, and give the real Sabnzbd impl a `Req.Test` stub:

```elixir
config :cinder, download_clients: %{
  torrent: Cinder.Download.ClientMock,
  usenet:  Cinder.Download.ClientMock
}

config :cinder, Cinder.Download.Client.Sabnzbd,
  base_url: "http://localhost:8080",
  api_key: "test-key",
  req_options: [plug: {Req.Test, Cinder.SabnzbdStub}, retry: false]
```

**Setup note (README / dev config):** SABnzbd must have **"Pause on Duplicates"
disabled** (see §7 `:not_found` caveat). Documented alongside the env vars.

### Docstring updates (don't leave stale references to the old key)

- `lib/cinder/download.ex:9` moduledoc references `config :cinder, :download_client` → update to `:download_clients`.
- `lib/cinder/catalog.ex` `transition/2` docstring and `movie.ex:48`
  `transition_changeset` `@doc` enumerate the settable keys → add `download_protocol`.

## Data flow (end to end)

```
Prowlarr search (unified)
  → normalize: %{title, size, download_url, seeders, protocol}
  → Release.new: %Release{… protocol: :torrent | :usenet}
  → Acquisition.best_release(protocols: available)   # §3: drop releases with no client
  → Scorer.select                                    # protocol-blind quality ranking
  → best %Release{}
Download.start
  → client_for(release.protocol) -> {:ok, client}; client.add(release) → {:ok, download_id}
  → Catalog.transition: :downloading, download_id, download_protocol   # atomic
Poller.advance (each tick)
  → client_for(movie.download_protocol) -> {:ok, client} | :error(->bounded :import_failed)
  → client.status(download_id)  # nzo_ids-scoped for SABnzbd
  → :completed + content_path → :downloaded → (existing import) → :available
```

## Import path (unchanged — verified)

`Library.import_movie` already accepts a **directory** `content_path`:
`resolve_source/1` (`library.ex:37-43`) checks `fs().dir?/1`, and for a directory
globs recursively (`find_files`) and `pick_video/1` (`library.ex:47-55`) selects
the largest video file by extension. SABnzbd's `storage` folder is the same shape
as a multi-file torrent's `content_path`, which this path was built for — so the
import, PubSub broadcasts, and `/status` dashboard need **no changes**; they key
off `status` and `file_path`, both protocol-agnostic.

## Scoring & Usenet size (honest caveat of "protocol-blind")

The scorer's `sort_key` is `{resolution_rank, -size}` (`scorer.ex:43-46`) and
ranks by **resolution preference first** (default `@default_preferred
["1080p","720p"]`, `scorer.ex:11`). So a 1080p torrent **beats** a 2160p NZB —
protocol-blind scoring does **not** auto-select giant 4K Usenet remuxes. The real
residual: **within a resolution tier, "largest size wins" tilts toward Usenet**,
whose reported size includes par2 repair blocks, so an NZB can out-"size" an
equivalent torrent without being better video. This is a mild mis-rank, not a
quota disaster, and it is the same unbounded-size behaviour that already exists
for torrents (no `max_size` is configured in prod today). Out of scope to fix
here; if it bites, wire a `max_size` (the scorer's band already supports it) or
add a Usenet-vs-torrent preference (see Out of scope). Flagged so the choice is
explicit.

## Error handling

- **Misrouted protocol (the winner)** — can't happen: the release carries the
  protocol from Prowlarr and the §3 filter guarantees the winner's protocol has a
  configured client, so `add`-time `client_for/1` always returns `{:ok, _}`.
- **Mislabeled-protocol release (not the winner path)** — an NZB defaulting to
  `:torrent` (§2 edge) → qBittorrent `:bad_torrent` → terminal `:search_failed`.
  Loud, non-corrupting; tested.
- **SABnzbd add rejected / duplicate** (`status:false` or empty `nzo_ids`) →
  `:add_rejected` → existing `{:error,_}` path → bounded retry → `:search_failed`.
- **NZB fails after add** (bad URL, unpack failure) → history `Failed` →
  `status` `:error` → poller's `retry_or_fail(:download_error, …)` →
  `:import_failed`. Same as a torrent error.
- **`nzo_id` not found** → `:not_found` → bounded retry → `:import_failed`.
  Realistic cause is duplicate-pause re-keying the id (see §7), not a purged
  history; remediation is the SABnzbd config requirement.
- **Missing client at poll time** (a protocol removed from config mid-download) →
  `client_for/1` returns `:error` → `retry_or_fail(movie, :no_client,
  :import_attempts, :import_failed)` (§6). Bounded and terminal, not an infinite
  hang. (Parks at `:import_failed` rather than a dedicated `:routing_failed` —
  consistent with the existing `:torrent_not_found → :import_failed` choice at
  `poller.ex:138`; a should-never-happen edge not worth a new status.)

## Testing (what proves it; `mix test` stays green, no network)

- **`Sabnzbd` unit test** (`Req.Test`, mirrors `qbittorrent_test.exs`):
  `add` → `nzo_id`; `add` empty `nzo_ids` → `:add_rejected`; `add` `status:false`
  → `:add_rejected`; queue slot → `:downloading` + coerced progress; history
  `Completed` → `:completed` with `content_path` = `storage`; history `Failed` →
  `:error`; a post-processing history status → `:downloading`; absent from both
  → `:not_found`. Assert the requests carry `nzo_ids=<id>`.
- **`Release` / `Prowlarr` protocol tests**: a `"usenet"` result yields
  `protocol: :usenet`; a torrent result yields `:torrent`; **a missing/unexpected
  `protocol` (e.g. an `.nzb` `downloadUrl` with no `protocol` key) yields
  `:torrent`** (documents the §2 conservative-default edge).
- **`Acquisition.best_release` protocol-filter test**: with `protocols:
  [:torrent]`, a Usenet release is excluded even if it would otherwise win; with
  no opt, all protocols pass.
- **Routing tests (must go through `Catalog.transition` + re-read, not a
  hand-built struct)**: a `:usenet` release's `add` and subsequent poll `status`
  go to the usenet-mapped client and the movie persists `download_protocol:
  :usenet`; a `:torrent` release's go to the torrent-mapped client. This catches a
  missing `:download_protocol` cast (silent-drop regression).
- **Poller missing-client test**: a movie with a `download_protocol` whose key is
  absent from `download_clients` advances to `:import_failed` after the bound
  (not an infinite `:downloading`).
- **Migration test**: column added; an existing row (`download_protocol: nil`)
  routes to `:torrent` at poll time.

## Out of scope (ponytail ceilings — add when needed)

- **Usenet-vs-torrent preference** — scorer is protocol-blind. Add a preference
  term to the sort key if you want "prefer Usenet on a tie."
- **`max_size` / quota guard** — not configured today (pre-existing for torrents);
  see "Scoring & Usenet size."
- **`addfile`** (uploading NZB bytes) — `addurl` covers Prowlarr's direct NZB
  links.
- **SABnzbd categories / priority / dedupe** — not set; SABnzbd defaults apply.
- **Multiple clients per protocol** — one module per protocol.
- **`/status` protocol indicator** — the dashboard (`status_live.ex`) doesn't show
  whether a `:downloading` movie is a torrent or an NZB. With the §6 bound,
  missing-client hangs are gone, so this is a debugging nicety, not a correctness
  need. A one-line protocol badge in `movie_status_badge`/the dashboard row is a
  cheap optional add the implementation plan may include; left out of the core
  scope.
