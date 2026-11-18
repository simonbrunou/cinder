defmodule Cinder.IndexerStubs do
  @moduledoc """
  Indexer stubs for acquisition tests: the seasons a standard TV search asks for, so a test can
  show the sweep and the manual panel query the same ones (#837), and the anime episode sweep's
  pick over releases a test has in hand.
  """

  alias Cinder.Acquisition.{Anime, InHandIndexerMock, Release}

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

  @doc """
  The anime episode sweep's pick (`Cinder.Acquisition.Anime.best_episodes/4`) for `wanted_ids`
  of `context`, when the indexer answers `releases`: each `search_tv/3` call with those that
  report a `tvdb_id`, each `search_tv_query/2` call with the rest. `releases` are indexer results
  or `%Release{}`s; a `%Release{}` goes back to the indexer as a map, and `Release.new/1` parses
  it again.

  The search keeps a result's own `query_origins`. A result without them gets the origin of the
  query that answered it: `[:id_scoped]` from `search_tv/3` when `context.tvdb_id` is set, else
  `[:free_text]`. The search drops a free-text result whose name doesn't lead with the series
  title or an alias (`Cinder.Acquisition.Anime.names_series?/2`), or that names another anime
  series (`Cinder.Acquisition.another_anime_series?/2`). It keeps an id-scoped one for the judge.
  So a test of such a name gives the context a TVDB id and reports that id on the result (#699).

  It stubs `Cinder.Acquisition.InHandIndexerMock`, a mock no other test sets, from the calling
  process.
  """
  def anime_sweep_pick(releases, context, wanted_ids, opts \\ []) do
    {id_reported, unreported} =
      releases |> Enum.map(&indexer_result/1) |> Enum.split_with(&Map.get(&1, :tvdb_id))

    Mox.stub(InHandIndexerMock, :search_tv, fn _tvdb_id, _title, _season -> {:ok, id_reported} end)

    Mox.stub(InHandIndexerMock, :search_tv_query, fn _query, _opts -> {:ok, unreported} end)

    Anime.best_episodes(InHandIndexerMock, context, wanted_ids, opts)
  end

  defp indexer_result(%Release{} = release), do: Map.from_struct(release)

  defp indexer_result(%{} = result), do: result
end
