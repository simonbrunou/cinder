defmodule Cinder.Jobs do
  @moduledoc """
  The household's periodic background sweeps — the ones with no per-item pipeline row to show on
  `/activity` (series metadata refresh, parked-title rehunt, subtitle backfill, Plex watchlist sync). `statuses/0` gives the activity view a
  last-run + schedule snapshot for each, read non-blocking from `:persistent_term` (see the
  stateless `Cinder.Download.PollerSkeleton`), so a page load never waits on a mid-sweep worker.
  """
  @workers [
    Cinder.Catalog.Refresher,
    Cinder.Catalog.Rehunter,
    Cinder.Subtitles.Sweeper,
    Cinder.Requests.WatchlistSync
  ]

  @doc "A last-run/interval snapshot for each background sweep, in display order."
  def statuses, do: Enum.map(@workers, & &1.status())
end
