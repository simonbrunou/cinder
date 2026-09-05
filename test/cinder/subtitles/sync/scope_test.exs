defmodule Cinder.Subtitles.Sync.ScopeTest do
  use Cinder.DataCase, async: false

  import Cinder.CatalogFixtures

  alias Cinder.Subtitles.Sync

  test "unit_for_video_path/2 resolves a movie by a targeted query, not a full catalog scan" do
    target_path = "/lib/Target (2020)/Target (2020).mkv"

    movie =
      movie_fixture(%{status: :available, file_path: target_path, title: "Target"})

    for n <- 1..25 do
      movie_fixture(%{status: :available, file_path: "/lib/Other#{n}/Other#{n}.mkv"})
    end

    handler = "scope-query-test-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler,
      [:cinder, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        send(parent, {:query, metadata.source, metadata.params})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert %{video_path: ^target_path, label: "Target", scopes: scopes} =
             Sync.unit_for_video_path(target_path, :movies)

    assert MapSet.member?(scopes, {:movie, movie.id})

    movie_queries = collect_queries([]) |> Enum.filter(&(&1.source == "movies"))
    refute movie_queries == []

    # Every query against the movies table was parameterized by the exact path we asked for —
    # not a blanket "every available movie" scan (issue #525) that happens to contain it.
    for %{params: params} <- movie_queries do
      assert target_path in params
    end
  end

  test "unit_for_video_path/2 resolves an episode by a targeted query, not a full catalog scan" do
    series = series_fixture()
    season = season_fixture(series)
    target_path = "/tv/Show/Season 01/Show - S01E05.mkv"

    episode =
      episode_fixture(season, %{episode_number: 5, title: "Target", file_path: target_path})

    for n <- 1..25 do
      episode_fixture(season, %{episode_number: 10 + n, file_path: "/tv/Show/Other#{n}.mkv"})
    end

    handler = "scope-query-test-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler,
      [:cinder, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        send(parent, {:query, metadata.source, metadata.params})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert %{video_path: ^target_path, scopes: scopes} =
             Sync.unit_for_video_path(target_path, :tv)

    assert MapSet.member?(scopes, {:episode, episode.id})

    episode_queries = collect_queries([]) |> Enum.filter(&(&1.source == "episodes"))
    refute episode_queries == []

    for %{params: params} <- episode_queries do
      assert target_path in params
    end
  end

  test "unit_for_video_path/2 is nil for a path no available movie or filed episode owns" do
    refute Sync.unit_for_video_path("/lib/Nobody/Nobody.mkv", :movies)
    refute Sync.unit_for_video_path("/tv/Nobody/Nobody.mkv", :tv)
  end

  defp collect_queries(acc) do
    receive do
      {:query, source, params} -> collect_queries([%{source: source, params: params} | acc])
    after
      0 -> acc
    end
  end
end
