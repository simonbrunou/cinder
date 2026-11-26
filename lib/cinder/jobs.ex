defmodule Cinder.Jobs do
  @moduledoc """
  The household's periodic background sweeps — the ones with no per-item pipeline row to show on
  `/activity` (series metadata refresh, parked-title rehunt, subtitle backfill, Plex watchlist
  sync, the indexer definitions update). `statuses/0` gives the activity view a last-run +
  schedule snapshot for each, read non-blocking from `:persistent_term`, so a page load never
  waits on a mid-sweep worker. Each worker but the last uses the stateless
  `Cinder.Download.PollerSkeleton`; `Cinder.Indexers.Definitions.Updater` is a GenServer of its
  own with the same `status/0` shape, whose `interval` is the delay armed after its last run.
  """
  @workers [
    Cinder.Catalog.Refresher,
    Cinder.Catalog.Rehunter,
    Cinder.Catalog.UpgradeHunter,
    Cinder.Download.Cleaner,
    Cinder.DatabaseBackup,
    Cinder.Subtitles.Sweeper,
    Cinder.Requests.WatchlistSync,
    Cinder.Indexers.Definitions.Updater
  ]

  @doc "A last-run/interval snapshot for each background sweep, in display order."
  def statuses, do: Enum.map(@workers, & &1.status())
end
