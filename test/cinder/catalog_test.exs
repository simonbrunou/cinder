defmodule Cinder.CatalogTest do
  use Cinder.DataCase, async: true

  import Mox

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Movie, Season, Series}

  setup :verify_on_exit!

  describe "search_movies/1" do
    test "delegates to the configured TMDB impl" do
      results = [%{tmdb_id: 27_205, title: "Inception", year: 2010, poster_path: "/p.jpg"}]
      expect(Cinder.Catalog.TMDBMock, :search, fn "inception" -> {:ok, results} end)

      assert {:ok, ^results} = Catalog.search_movies("inception")
    end

    test "short-circuits a blank query without calling TMDB" do
      # No expect/3 is set, so verify_on_exit! proves the mock was never called.
      assert {:ok, []} = Catalog.search_movies("")
      assert {:ok, []} = Catalog.search_movies("   ")
    end

    test "passes a TMDB error straight through" do
      expect(Cinder.Catalog.TMDBMock, :search, fn _ -> {:error, :timeout} end)

      assert {:error, :timeout} = Catalog.search_movies("inception")
    end
  end

  describe "get_movie/1" do
    test "delegates to the configured TMDB impl" do
      expect(Cinder.Catalog.TMDBMock, :get_movie, fn 27_205 ->
        {:ok, %{tmdb_id: 27_205, imdb_id: "tt1375666"}}
      end)

      assert {:ok, %{imdb_id: "tt1375666"}} = Catalog.get_movie(27_205)
    end
  end

  describe "transition/2, list_by_status/1, subscribe/0" do
    test "transition/2 updates status + download_id and broadcasts the change" do
      {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 1, title: "M"})
      Catalog.subscribe()

      assert {:ok, %Movie{status: :downloading, download_id: "h"}} =
               Catalog.transition(movie, %{status: :downloading, download_id: "h"})

      assert_receive {:movie_updated, %Movie{id: id, status: :downloading}}
      assert id == movie.id
    end

    test "transition/2 rejects an unknown status" do
      {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 2, title: "M"})

      assert {:error, changeset} = Catalog.transition(movie, %{status: :bogus})
      assert %{status: ["is invalid"]} = errors_on(changeset)
    end

    test "transition/2 accepts :cancelled as a valid status" do
      {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 4242, title: "M"})

      assert {:ok, %Movie{status: :cancelled}} =
               Catalog.transition(movie, %{status: :cancelled})
    end

    test "transition/2 persists file_path" do
      {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 9001, title: "Heat"})

      assert {:ok, %Movie{file_path: "/downloads/Heat.1995.mkv"}} =
               Catalog.transition(movie, %{
                 status: :downloaded,
                 file_path: "/downloads/Heat.1995.mkv"
               })

      assert %Movie{file_path: "/downloads/Heat.1995.mkv"} = Repo.get!(Movie, movie.id)
    end

    test "list_by_status/1 returns only movies in that status" do
      {:ok, _a} = Catalog.add_to_watchlist(%{tmdb_id: 4, title: "A"})
      {:ok, b} = Catalog.add_to_watchlist(%{tmdb_id: 5, title: "B"})
      {:ok, _} = Catalog.transition(b, %{status: :downloading, download_id: "h"})

      assert [%Movie{tmdb_id: 5}] = Catalog.list_by_status(:downloading)
      assert [%Movie{tmdb_id: 4}] = Catalog.list_by_status(:requested)
    end
  end

  describe "retry_movie/1" do
    test "resets a parked movie to :requested, zeroes attempt counters, and broadcasts" do
      Catalog.subscribe()

      for {tmdb_id, parked} <- [{8001, :no_match}, {8002, :search_failed}, {8003, :import_failed}] do
        {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: tmdb_id, title: "M"})

        {:ok, movie} =
          Catalog.transition(movie, %{
            status: parked,
            search_attempts: 7,
            import_attempts: 4,
            download_id: "abc",
            download_protocol: :usenet,
            file_path: "/downloads/x.mkv"
          })

        assert {:ok,
                %Movie{
                  status: :requested,
                  search_attempts: 0,
                  import_attempts: 0,
                  download_id: nil,
                  download_protocol: nil,
                  file_path: nil
                } = retried} = Catalog.retry_movie(movie)

        expected_id = retried.id
        assert_receive {:movie_updated, %Movie{id: ^expected_id, status: :requested}}
      end
    end

    test "refuses to retry a movie that is not in a parked state" do
      {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 8100, title: "M"})
      {:ok, downloading} = Catalog.transition(movie, %{status: :downloading, download_id: "h"})

      assert {:error, :not_retryable} = Catalog.retry_movie(downloading)
      assert Catalog.get_movie_by_id(movie.id).status == :downloading
    end
  end

  describe "get_movie_by_id/1" do
    test "returns the movie by primary key, or nil" do
      {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 7001, title: "M"})
      assert %Cinder.Catalog.Movie{id: id} = Catalog.get_movie_by_id(movie.id)
      assert id == movie.id
      assert Catalog.get_movie_by_id(-1) == nil
    end
  end

  describe "search_failed terminal + search_attempts" do
    test "transition can set :search_failed and persist search_attempts" do
      {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 7002, title: "M"})
      {:ok, m} = Catalog.transition(movie, %{status: :searching, search_attempts: 3})
      assert m.search_attempts == 3
      {:ok, m} = Catalog.transition(m, %{status: :search_failed})
      assert m.status == :search_failed
    end
  end

  describe "find_or_create_at_requested/1" do
    @attrs %{tmdb_id: 603, title: "The Matrix", year: 1999, poster_path: "/p.jpg"}

    test "creates a movie at :requested when absent" do
      assert {:ok, movie} = Catalog.find_or_create_at_requested(@attrs)
      assert movie.status == :requested
      assert movie.tmdb_id == 603
    end

    test "reuses an existing movie without resetting its status" do
      {:ok, movie} = Catalog.add_to_watchlist(@attrs)
      {:ok, movie} = Catalog.transition(movie, %{status: :available})
      assert {:ok, found} = Catalog.find_or_create_at_requested(@attrs)
      assert found.id == movie.id
      assert found.status == :available
    end

    test "broadcasts {:movie_created, movie} on insert" do
      Catalog.subscribe()
      {:ok, movie} = Catalog.find_or_create_at_requested(@attrs)
      assert_receive {:movie_created, ^movie}
    end
  end

  describe "add_to_watchlist/1 and list_watchlist/0" do
    @attrs %{tmdb_id: 27_205, title: "Inception", year: 2010, poster_path: "/p.jpg"}

    test "persists a movie as :requested and lists it" do
      assert {:ok, %Movie{} = movie} = Catalog.add_to_watchlist(@attrs)
      assert movie.tmdb_id == 27_205
      assert movie.title == "Inception"
      assert movie.status == :requested

      assert [%Movie{tmdb_id: 27_205, status: :requested}] = Catalog.list_watchlist()
    end

    test "accepts a movie with a nil year and poster_path" do
      attrs = %{tmdb_id: 1, title: "Obscure", year: nil, poster_path: nil}
      assert {:ok, %Movie{year: nil, poster_path: nil}} = Catalog.add_to_watchlist(attrs)
    end

    test "rejects a duplicate tmdb_id" do
      assert {:ok, _} = Catalog.add_to_watchlist(@attrs)
      assert {:error, changeset} = Catalog.add_to_watchlist(@attrs)
      assert %{tmdb_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "requires tmdb_id and title" do
      assert {:error, changeset} = Catalog.add_to_watchlist(%{})
      assert %{tmdb_id: ["can't be blank"], title: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "cancellable?/1" do
    test "is true for active statuses and false for terminal/parked ones" do
      for s <- [:requested, :searching, :downloading, :downloaded] do
        assert Catalog.cancellable?(%Movie{status: s}), "expected #{s} cancellable"
      end

      for s <- [:available, :no_match, :search_failed, :import_failed, :cancelled] do
        refute Catalog.cancellable?(%Movie{status: s}), "expected #{s} NOT cancellable"
      end
    end
  end

  describe "delete broadcasts" do
    test "broadcast_movie_deleted/1 emits {:movie_deleted, id} on the movies topic" do
      Catalog.subscribe()
      assert :ok = Catalog.broadcast_movie_deleted(42)
      assert_receive {:movie_deleted, 42}
    end

    test "broadcast_series_deleted/1 emits {:series_deleted, id} on the series topic" do
      Catalog.subscribe_series()
      assert :ok = Catalog.broadcast_series_deleted(7)
      assert_receive {:series_deleted, 7}
    end
  end

  describe "set_movie_language/2" do
    test "re-queues a parked movie" do
      {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 7, title: "X"})
      {:ok, movie} = Catalog.transition(movie, %{status: :no_match})

      {:ok, updated} = Catalog.set_movie_language(movie, "french")

      assert updated.preferred_language == "french"
      assert updated.status == :requested
      assert updated.search_attempts == 0
    end

    test "on an available movie only updates the field" do
      {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 8, title: "Y"})
      {:ok, movie} = Catalog.transition(movie, %{status: :available})

      {:ok, updated} = Catalog.set_movie_language(movie, "any")

      assert updated.preferred_language == "any"
      assert updated.status == :available
    end
  end

  describe "set_series_language/2" do
    test "zeroes search_attempts on wanted episodes only" do
      series = Repo.insert!(%Series{tmdb_id: 5, title: "S"})
      season = Repo.insert!(%Season{series_id: series.id, season_number: 1, monitored: true})

      wanted =
        Repo.insert!(%Episode{
          season_id: season.id,
          episode_number: 1,
          monitored: true,
          search_attempts: 9
        })

      filed =
        Repo.insert!(%Episode{
          season_id: season.id,
          episode_number: 2,
          monitored: true,
          search_attempts: 9,
          file_path: "/x.mkv"
        })

      {:ok, updated} = Catalog.set_series_language(series, "french")

      assert updated.preferred_language == "french"
      assert Repo.get!(Episode, wanted.id).search_attempts == 0
      assert Repo.get!(Episode, filed.id).search_attempts == 9
    end
  end
end
