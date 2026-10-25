defmodule Cinder.IndexerStubs do
  @moduledoc """
  Records the seasons a standard TV search asks the indexer for, so a test can show the sweep and
  the manual panel query the same ones (#837).
  """

  @doc """
  Stubs `Cinder.Acquisition.IndexerMock.search_tv/3` for the series `tvdb_id` and `title`: each
  query answers `Map.get(by_season, season, [])` and tells the calling test which season it asked
  for. A query from another process (a LiveView, the poller) needs `Mox.set_mox_global/1`.
  """
  def stub_search_tv(tvdb_id, title, by_season) do
    test_pid = self()

    Mox.stub(Cinder.Acquisition.IndexerMock, :search_tv, fn ^tvdb_id, ^title, season ->
      send(test_pid, {:searched_season, season})
      {:ok, Map.get(by_season, season, [])}
    end)
  end

  @doc "The seasons queried since the last call, in ascending order, one entry per query."
  def searched_seasons(acc \\ []) do
    receive do
      {:searched_season, season} -> searched_seasons([season | acc])
    after
      0 -> Enum.sort(acc)
    end
  end
end
