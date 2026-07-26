defmodule Cinder.Download.StallReaper do
  @moduledoc """
  Detects a download that makes no forward progress for a configurable window (a dead torrent
  swarm, `metaDL` with 0 seeders, a frozen job) so the pollers can reap it — remove it from the
  client, blocklist the release, and re-search a different one. **On by default** — the shipped
  `config/config.exs` sets `enabled: true`; set `enabled: false` to disable. (`enabled?/0`'s own
  fallback is `false`, so an install with no config block at all stays off — fail-safe.)

  Pure: no DB, no HTTP. The stall clock is *derived from the row's `updated_at`*, not a dedicated
  column. `Catalog.update_movie_download_metrics`/`update_grab_download_metrics` are change-gated —
  when `progress`/`speed`/`eta` are all unchanged they write nothing, so `updated_at` freezes at the
  moment the download last made progress. Therefore `now - updated_at` is the stall duration.

  `speed == 0` is a *hard numeric zero* (`=== 0`): SABnzbd reports `speed: nil`, so the seed-window
  reap is torrent-only for free. Threshold is picked from the connected-seed count: `0 →
  no_seeders_timeout` (a dead/`metaDL` swarm), anything else (including `nil`/unknown) → the longer
  `stall_timeout`.

  On top of that seed-aware window sits a **protocol-agnostic absolute cap** (`max_downloading_timeout`,
  default 24h): a download whose derived stall clock crosses it is reaped no matter its `speed` or
  protocol. That's the safety net for a usenet job wedged at `:downloading` (SABnzbd "Pause on
  Duplicates", missing-article limbo, an endless repair) that the torrent-only seed window can never
  catch — it never errors, never advances, so without the cap it sits forever. The cap is generous on
  purpose: a genuinely-progressing download keeps writing fresh metrics, so its `updated_at` never
  ages anywhere near 24h; only a truly frozen one does.

  ## ponytail: the derivation rests on an emergent invariant

  At a true stall all three change-gated fields are byte-stable — `progress` frozen, `speed` a hard
  `0` (or `nil` for usenet), and `eta` qBittorrent's `8_640_000` infinity sentinel that
  `QBittorrent.normalize/1` maps to `nil`. If a future change adds a field to `Cinder.Catalog`'s
  `@download_metric_fields` that wobbles while frozen, or alters the eta normalization, `updated_at`
  stops freezing and *both* reap paths silently never fire. `Cinder.Download.PollerTest` locks this
  with a two-tick `updated_at`-freeze assertion.
  """

  # All in milliseconds (matched to `DateTime.diff(_, _, :millisecond)`).
  @default_stall_timeout :timer.hours(2)
  @default_no_seeders_timeout :timer.minutes(30)
  @default_max_downloading_timeout :timer.hours(24)

  @doc "Whether the reaper is enabled (`config :cinder, #{inspect(__MODULE__)}, enabled: true`)."
  def enabled?, do: Keyword.get(config(), :enabled, false)

  @doc "No-progress window (ms) before a still-seeded download is reaped."
  def stall_timeout, do: Keyword.get(config(), :stall_timeout, @default_stall_timeout)

  @doc "Shorter no-progress window (ms) for a 0-seeder (dead/metaDL) swarm."
  def no_seeders_timeout,
    do: Keyword.get(config(), :no_seeders_timeout, @default_no_seeders_timeout)

  @doc "Absolute, protocol-agnostic no-progress cap (ms) — reaps a wedged usenet/frozen job the seed window can't."
  def max_downloading_timeout,
    do: Keyword.get(config(), :max_downloading_timeout, @default_max_downloading_timeout)

  @doc """
  True when a download reported `status` (a `Client.status/1` map) has been stalled since
  `updated_at` past a reap threshold. Two ways to cross: a hard-`0` `speed` (torrents) past its
  seed-dependent window, **or** — regardless of speed/protocol — past the absolute
  `max_downloading_timeout`, which catches a usenet job (`speed: nil`) wedged at `:downloading`.
  `now`/`updated_at` are `DateTime`s (both schemas store `:utc_datetime`).
  """
  def reap?(updated_at, status, now) do
    stalled_ms = DateTime.diff(now, updated_at, :millisecond)

    (Map.get(status, :speed) === 0 and stalled_ms >= threshold(Map.get(status, :seeders))) or
      stalled_ms >= max_downloading_timeout()
  end

  defp threshold(seeders) when seeders === 0, do: no_seeders_timeout()
  defp threshold(_seeders), do: stall_timeout()

  defp config, do: Application.get_env(:cinder, __MODULE__, [])
end
