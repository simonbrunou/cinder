defmodule Cinder.Catalog.RehunterTest do
  # async: false — the sweep runs in its own process against the test-owned (shared Sandbox)
  # connection, and status/0 stamps process-global :persistent_term.
  use Cinder.DataCase, async: false

  @moduletag :capture_log

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Movie, Rehunter}

  import Cinder.CatalogFixtures

  @rehunt_after :timer.hours(24)

  setup do
    on_exit(fn -> :persistent_term.erase({Rehunter, :last_run}) end)
    # Long interval: every test drives the sweep synchronously via poll/0, never the timer.
    start_supervised!({Rehunter, interval: 60_000})
    :ok
  end

  # `updated_at` is Ecto-managed, so a fixture always lands "now". Backdate it directly — that
  # column IS the cooldown clock the sweep reads.
  defp backdate(schema, id, ago_ms) do
    at = DateTime.add(DateTime.utc_now(), -ago_ms, :millisecond) |> DateTime.truncate(:second)
    Repo.update_all(from(r in schema, where: r.id == ^id), set: [updated_at: at])
  end

  defp poll, do: assert(:ok = Rehunter.poll())

  describe "movies" do
    test "re-queues a parked movie that has rested past the cooldown" do
      for status <- [:no_match, :search_failed] do
        movie = movie_fixture(%{status: status, search_attempts: 10})
        backdate(Movie, movie.id, @rehunt_after + 1000)

        poll()

        assert %Movie{status: :requested, search_attempts: 0} = Repo.get!(Movie, movie.id)
      end
    end

    test "leaves a parked movie still inside the cooldown alone" do
      movie = movie_fixture(%{status: :no_match})
      backdate(Movie, movie.id, div(@rehunt_after, 2))

      poll()

      assert %Movie{status: :no_match} = Repo.get!(Movie, movie.id)
    end

    test "never touches :import_failed — a broken import is not a missing release" do
      movie = movie_fixture(%{status: :import_failed, file_path: "/lib/m.mkv"})
      backdate(Movie, movie.id, @rehunt_after + 1000)

      poll()

      assert %Movie{status: :import_failed} = Repo.get!(Movie, movie.id)
    end

    test "never touches an in-flight or available movie" do
      for status <- [:requested, :downloading, :available] do
        movie = movie_fixture(%{status: status})
        backdate(Movie, movie.id, @rehunt_after + 1000)

        poll()

        assert Repo.get!(Movie, movie.id).status == status
      end
    end
  end

  describe "episodes" do
    setup do
      series = series_fixture()
      season = season_fixture(series)
      %{series: series, season: season}
    end

    test "zeroes attempts on a search-parked episode so it re-enters the sweep", %{season: season} do
      episode = episode_fixture(season, %{search_attempts: Catalog.max_search_attempts()})
      backdate(Episode, episode.id, @rehunt_after + 1000)

      assert Catalog.episode_state(episode) == :search_parked

      poll()

      assert Repo.get!(Episode, episode.id).search_attempts == 0
      assert Catalog.episode_state(Repo.get!(Episode, episode.id)) == :wanted
    end

    test "leaves a parked episode inside the cooldown alone", %{season: season} do
      attempts = Catalog.max_search_attempts()
      episode = episode_fixture(season, %{search_attempts: attempts})
      backdate(Episode, episode.id, div(@rehunt_after, 2))

      poll()

      assert Repo.get!(Episode, episode.id).search_attempts == attempts
    end

    test "leaves an imported or grabbed episode alone", %{season: season} do
      attempts = Catalog.max_search_attempts()

      imported =
        episode_fixture(season, %{
          episode_number: 1,
          search_attempts: attempts,
          file_path: "/lib/s01e01.mkv"
        })

      backdate(Episode, imported.id, @rehunt_after + 1000)

      poll()

      assert Repo.get!(Episode, imported.id).search_attempts == attempts
    end

    test "broadcasts the series so open views re-render", %{series: series, season: season} do
      episode = episode_fixture(season, %{search_attempts: Catalog.max_search_attempts()})
      backdate(Episode, episode.id, @rehunt_after + 1000)

      series_id = series.id
      Catalog.subscribe_series()

      poll()

      assert_receive {:series_updated, ^series_id}
    end
  end

  test "does nothing at all when disabled" do
    original = Application.get_env(:cinder, Rehunter, [])
    Application.put_env(:cinder, Rehunter, enabled: false)
    on_exit(fn -> Application.put_env(:cinder, Rehunter, original) end)

    movie = movie_fixture(%{status: :no_match})
    backdate(Movie, movie.id, @rehunt_after + 1000)

    poll()

    assert %Movie{status: :no_match} = Repo.get!(Movie, movie.id)
  end
end
