defmodule Cinder.CatalogTest do
  use Cinder.DataCase, async: true

  import Mox

  alias Cinder.Catalog
  alias Cinder.Catalog.Movie

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

    test "list_by_status/1 returns only movies in that status" do
      {:ok, _a} = Catalog.add_to_watchlist(%{tmdb_id: 4, title: "A"})
      {:ok, b} = Catalog.add_to_watchlist(%{tmdb_id: 5, title: "B"})
      {:ok, _} = Catalog.transition(b, %{status: :downloading, download_id: "h"})

      assert [%Movie{tmdb_id: 5}] = Catalog.list_by_status(:downloading)
      assert [%Movie{tmdb_id: 4}] = Catalog.list_by_status(:requested)
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
end
