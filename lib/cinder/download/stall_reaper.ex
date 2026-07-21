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

  `speed == 0` is a *hard numeric zero* (`=== 0`): SABnzbd reports `speed: nil`, so a usenet job is
  never reaped — the reaper is torrent-only for free. Threshold is picked from the connected-seed
  count: `0 → no_seeders_timeout` (a dead/`metaDL` swarm), anything else (including `nil`/unknown) →
  the longer `stall_timeout`.

  ## ponytail: the derivation rests on an emergent invariant

  At a true stall all three change-gated fields are byte-stable — `progress` frozen, `speed` a hard
  `0`, and `eta` qBittorrent's `8_640_000` infinity sentinel that `QBittorrent.normalize/1` maps to
  `nil`. If a future change adds a field to `Cinder.Catalog`'s `@download_metric_fields` that wobbles
  at zero speed, or alters the eta normalization, `updated_at` stops freezing and the reaper silently
  never fires. `Cinder.Download.PollerTest` locks this with a two-tick `updated_at`-freeze assertion.
  """

  # Both in milliseconds (matched to `DateTime.diff(_, _, :millisecond)`).
  @default_stall_timeout :timer.hours(2)
  @default_no_seeders_timeout :timer.minutes(30)

  @doc "Whether the reaper is enabled (`config :cinder, #{inspect(__MODULE__)}, enabled: true`)."
  def enabled?, do: Keyword.get(config(), :enabled, false)

  @doc "No-progress window (ms) before a still-seeded download is reaped."
  def stall_timeout, do: Keyword.get(config(), :stall_timeout, @default_stall_timeout)

  @doc "Shorter no-progress window (ms) for a 0-seeder (dead/metaDL) swarm."
  def no_seeders_timeout,
    do: Keyword.get(config(), :no_seeders_timeout, @default_no_seeders_timeout)

  @doc """
  True when a download reported `status` (a `Client.status/1` map) has been stalled since
  `updated_at` past its seed-dependent threshold. `speed` must be a hard `0` (torrents only —
  usenet's `nil` speed is never reaped). `now`/`updated_at` are `DateTime`s (both schemas store
  `:utc_datetime`).
  """
  def reap?(updated_at, status, now) do
    Map.get(status, :speed) === 0 and
      DateTime.diff(now, updated_at, :millisecond) >= threshold(Map.get(status, :seeders))
  end

  defp threshold(seeders) when seeders === 0, do: no_seeders_timeout()
  defp threshold(_seeders), do: stall_timeout()

  defp config, do: Application.get_env(:cinder, __MODULE__, [])
end
