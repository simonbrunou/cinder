defmodule Cinder.Library.MediaServer.ReconcilerTest do
  use Cinder.DataCase, async: false

  import Cinder.CatalogFixtures
  import Mox

  alias Cinder.Catalog
  alias Cinder.Catalog.MediaServerSeasons
  alias Cinder.Library.MediaServer.Reconciler
  alias Cinder.Library.MediaServerMock

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    on_exit(fn -> :persistent_term.erase({Reconciler, :last_run}) end)
    :ok
  end

  test "a complete inventory sets current ids and clears vanished ones" do
    current = movie_fixture(%{tmdb_id: 1})
    vanished = movie_fixture(%{tmdb_id: 2})
    series = series_fixture(%{tmdb_id: 3})

    assert {:ok, [_]} =
             Catalog.reconcile_media_server_items(:movies, [
               %{tmdb_id: vanished.tmdb_id, id: "plex:machine:old"}
             ])

    expect(MediaServerMock, :list_items, 2, fn
      :movies -> {:ok, [%{tmdb_id: current.tmdb_id, id: "plex:machine:new"}]}
      :tv -> {:ok, [%{tmdb_id: series.tmdb_id, id: "plex:machine:show"}]}
    end)

    expect(MediaServerMock, :list_seasons, fn -> {:ok, []} end)

    {:ok, pid} = start_supervised({Reconciler, name: :media_server_reconciler_test})
    assert :ok = Reconciler.poll(pid)

    assert Catalog.get_movie_by_tmdb_id(current.tmdb_id).media_server_item_id ==
             "plex:machine:new"

    assert Catalog.get_movie_by_tmdb_id(vanished.tmdb_id).media_server_item_id == nil

    assert Catalog.get_series_by_tmdb_id(series.tmdb_id).media_server_item_id ==
             "plex:machine:show"
  end

  test "provider errors and crashes never clear ids, and one kind cannot stop the other" do
    movie = movie_fixture(%{tmdb_id: 1})
    series = series_fixture(%{tmdb_id: 2})

    assert {:ok, [_]} =
             Catalog.reconcile_media_server_items(:movies, [
               %{tmdb_id: movie.tmdb_id, id: "jellyfin:movie-old"}
             ])

    expect(MediaServerMock, :list_items, 2, fn
      :movies -> raise "provider crashed"
      :tv -> {:ok, [%{tmdb_id: series.tmdb_id, id: "jellyfin:series-new"}]}
    end)

    expect(MediaServerMock, :list_seasons, fn -> {:ok, []} end)

    {:ok, pid} = start_supervised({Reconciler, name: :media_server_reconciler_crash_test})
    assert :ok = Reconciler.poll(pid)

    assert Catalog.get_movie_by_tmdb_id(movie.tmdb_id).media_server_item_id ==
             "jellyfin:movie-old"

    assert Catalog.get_series_by_tmdb_id(series.tmdb_id).media_server_item_id ==
             "jellyfin:series-new"
  end

  test "a partial-inventory error leaves every existing id untouched" do
    movie = movie_fixture(%{tmdb_id: 1})

    assert {:ok, [_]} =
             Catalog.reconcile_media_server_items(:movies, [
               %{tmdb_id: movie.tmdb_id, id: "plex:machine:old"}
             ])

    expect(MediaServerMock, :list_items, 2, fn
      :movies -> {:error, :partial_inventory}
      :tv -> {:ok, []}
    end)

    expect(MediaServerMock, :list_seasons, fn -> {:ok, []} end)

    {:ok, pid} = start_supervised({Reconciler, name: :media_server_reconciler_partial_test})
    assert :ok = Reconciler.poll(pid)

    assert Catalog.get_movie_by_tmdb_id(movie.tmdb_id).media_server_item_id ==
             "plex:machine:old"
  end

  defp season(tmdb_id, number, count, item_id),
    do: %{tmdb_id: tmdb_id, season_number: number, episode_count: count, item_id: item_id}

  defp poll_seasons(name, result) do
    expect(MediaServerMock, :list_items, 2, fn _kind -> {:ok, []} end)
    expect(MediaServerMock, :list_seasons, fn -> result end)

    pid = start_supervised!({Reconciler, name: name}, id: name)
    assert :ok = Reconciler.poll(pid)
    stop_supervised!(name)
  end

  test "a complete season inventory replaces the stored one and broadcasts only on change" do
    assert {:ok, :replaced} = MediaServerSeasons.replace([season(9, 1, 3, "plex:m:9")])
    Catalog.subscribe_series()

    # The same show listed twice keeps the season with more episodes.
    inventory = [season(1399, 1, 10, "plex:m:44"), season(1399, 1, 4, "plex:m:45")]
    poll_seasons(:media_server_seasons_test, {:ok, inventory})

    assert [%{season_number: 1, episode_count: 10, item_id: "plex:m:44"}] =
             MediaServerSeasons.for_series(1399)

    assert MediaServerSeasons.for_series(9) == []
    assert MediaServerSeasons.series_tmdb_ids() == MapSet.new([1399])
    assert_receive :media_server_seasons_updated

    poll_seasons(:media_server_seasons_again_test, {:ok, inventory})
    refute_receive :media_server_seasons_updated
  end

  test "a failed season read keeps the inventory; an unconfigured server clears it" do
    assert {:ok, :replaced} = MediaServerSeasons.replace([season(9, 1, 3, "plex:m:9")])

    poll_seasons(:media_server_seasons_partial_test, {:error, :partial_inventory})
    assert [%{episode_count: 3}] = MediaServerSeasons.for_series(9)

    poll_seasons(:media_server_seasons_section_test, {:error, {:plex_section_unset, :tv}})
    assert MediaServerSeasons.for_series(9) == []

    assert {:ok, :replaced} = MediaServerSeasons.replace([season(9, 1, 3, "plex:m:9")])
    poll_seasons(:media_server_seasons_unconfigured_test, {:error, :not_configured})
    assert MediaServerSeasons.for_series(9) == []
  end

  test "is supervised only when polling is enabled" do
    original = Application.get_env(:cinder, :start_poller, true)
    on_exit(fn -> Application.put_env(:cinder, :start_poller, original) end)

    Application.put_env(:cinder, :start_poller, false)
    refute Reconciler in Cinder.Application.poller_child()

    Application.put_env(:cinder, :start_poller, true)
    assert Reconciler in Cinder.Application.poller_child()
  end
end
