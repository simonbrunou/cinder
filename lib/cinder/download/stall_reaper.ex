defmodule Cinder.Download.StallReaper do
  @moduledoc """
  Detects a download that makes no forward progress for a configurable window (a dead torrent
  swarm, `metaDL` with 0 seeders, a frozen job) so the pollers can reap it — remove it from the
  client, blocklist the release, and re-search a different one. **On by default** — the shipped
  `config/config.exs` sets `enabled: true`; set `enabled: false` to disable. (`enabled?/0`'s own
  fallback is `false`, so an install with no config block at all stays off — fail-safe.)

  Pure: no DB, no HTTP. The seed-aware zero-speed window keeps its original clock: metric writes
  are change-gated, so `updated_at` freezes while `progress`/`speed`/`eta` are unchanged. The
  protocol-agnostic absolute cap uses the dedicated `download_progress_at` clock instead.

  `speed == 0` is a *hard numeric zero* (`=== 0`): SABnzbd reports `speed: nil`, so the seed-window
  reap is torrent-only for free. Threshold is picked from the connected-seed count: `0 →
  no_seeders_timeout` (a dead/`metaDL` swarm), anything else (including `nil`/unknown) → the longer
  `stall_timeout`.

  On top of that seed-aware window sits a **protocol-agnostic absolute cap** (`max_downloading_timeout`,
  default 24h): a download whose derived stall clock crosses it is reaped no matter its `speed` or
  protocol. That's the safety net for a usenet job wedged at `:downloading` (SABnzbd "Pause on
  Duplicates", missing-article limbo, an endless repair) that the torrent-only seed window can never
  catch — it never errors, never advances, so without the cap it sits forever. The cap is generous
  on purpose: genuine completion progress advances `download_progress_at`; speed/ETA jitter and
  transient metric clearing do not.

  ## ponytail: completion is the available progress signal

  Clients expose completion fraction, not downloaded bytes. Catalog keeps that fraction as a
  per-download high-water mark and advances `download_progress_at` only when it rises; entering or
  leaving the download lifecycle also advances it. If a client later exposes reliable byte counts,
  prefer those only when a real completion-fraction blind spot is observed.
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
  True when a download reported `status` (a `Client.status/1` map) crosses either clock: a hard-`0`
  `speed` (torrents) since `updated_at` past its seed-dependent window, **or** — regardless of
  speed/protocol — no completion advancement since `download_progress_at` past the absolute
  `max_downloading_timeout`. Timestamps are `DateTime`s (`:utc_datetime` in both schemas).
  """
  def reap?(updated_at, download_progress_at, status, now) do
    stalled_ms = DateTime.diff(now, updated_at, :millisecond)
    no_progress_ms = DateTime.diff(now, download_progress_at || updated_at, :millisecond)

    (Map.get(status, :speed) === 0 and stalled_ms >= threshold(Map.get(status, :seeders))) or
      no_progress_ms >= max_downloading_timeout()
  end

  defp threshold(seeders) when seeders === 0, do: no_seeders_timeout()
  defp threshold(_seeders), do: stall_timeout()

  defp config, do: Application.get_env(:cinder, __MODULE__, [])
end
