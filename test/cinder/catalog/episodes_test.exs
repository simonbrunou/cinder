defmodule Cinder.Catalog.EpisodesTest do
  use Cinder.DataCase, async: true

  import Cinder.CatalogFixtures

  alias Cinder.Catalog.{Episodes, Events}

  describe "announce/2" do
    setup do
      :ok = Events.subscribe_series()
      ref = :telemetry_test.attach_event_handlers(self(), [[:cinder, :transition]])
      %{ref: ref}
    end

    test "announces each series once and each episode's state once", %{ref: ref} do
      first = series_fixture()
      first_season = season_fixture(first)
      available = episode_fixture(first_season, %{file_path: "/tv/a/S01E01.mkv"})
      wanted = episode_fixture(first_season, %{episode_number: 2})
      second = series_fixture()
      upcoming = second |> season_fixture() |> episode_fixture(%{air_date: nil})

      assert :ok = Episodes.announce([available, wanted, upcoming])

      first_id = first.id
      second_id = second.id
      assert_receive {:series_updated, ^first_id}
      assert_receive {:series_updated, ^second_id}
      refute_received {:series_updated, ^first_id}

      states =
        for _episode <- 1..3 do
          assert_receive {[:cinder, :transition], ^ref, %{count: 1}, %{kind: :episode, to: to}}
          to
        end

      assert Enum.sort(states) == [:available, :upcoming, :wanted]
      refute_received {[:cinder, :transition], ^ref, _, _}
    end

    test "also announces series that lost every written episode", %{ref: ref} do
      series = series_fixture()

      assert :ok = Episodes.announce([], [series.id])

      series_id = series.id
      assert_receive {:series_updated, ^series_id}
      refute_received {[:cinder, :transition], ^ref, _, _}
    end
  end

  describe "series_ids/1" do
    test "lists each series holding one of the episodes once" do
      first = series_fixture()
      first_season = season_fixture(first)
      one = episode_fixture(first_season)
      two = episode_fixture(first_season, %{episode_number: 2})
      second = series_fixture()
      three = second |> season_fixture() |> episode_fixture()

      assert Enum.sort(Episodes.series_ids([one.id, two.id, three.id])) ==
               Enum.sort([first.id, second.id])

      assert Episodes.series_ids([]) == []
    end

    test "series_id/1 names the series that holds one episode" do
      series = series_fixture()
      episode = series |> season_fixture() |> episode_fixture()

      assert Episodes.series_id(episode) == series.id
    end
  end

  describe "state/2" do
    test "a monitored aired episode past the search budget is search-parked" do
      season = series_fixture() |> season_fixture()
      budget = Episodes.max_search_attempts()

      assert Episodes.state(episode_fixture(season, %{search_attempts: budget - 1})) == :wanted

      assert Episodes.state(
               episode_fixture(season, %{episode_number: 2, search_attempts: budget})
             ) ==
               :search_parked
    end
  end
end
