defmodule Cinder.CatalogMetadataTest do
  use Cinder.DataCase, async: false

  import Ecto.Query
  import Mox
  import Cinder.CatalogFixtures

  alias Cinder.Catalog
  alias Cinder.Catalog.{Movie, Series}

  @moduletag :capture_log

  setup :verify_on_exit!

  @details %{
    title: "Inception",
    year: 2010,
    poster_path: "/p.jpg",
    imdb_id: "tt1375666",
    original_language: "en",
    overview: "A thief who steals corporate secrets through dream-sharing.",
    runtime: 148,
    genres: ["Action", "Science Fiction"],
    vote_average: 8.4,
    release_date: ~D[2010-07-16]
  }

  describe "prepare_requested_movie/1" do
    test "fetches details and aliases before the database-only insert" do
      details = Map.put(@details, :tmdb_id, 372_058)

      expect(Cinder.Catalog.TMDBMock, :get_movie, fn 372_058 -> {:ok, details} end)

      expect(Cinder.Catalog.TMDBMock, :get_movie_alternative_titles, fn 372_058 ->
        {:ok, [%{title: "Kimi no Na wa.", country_code: "JP", kind: :alternative}]}
      end)

      assert {:ok, prepared} =
               Catalog.prepare_requested_movie(%{
                 tmdb_id: 372_058,
                 preferred_language: "french",
                 media_profile: :anime
               })

      assert Repo.get_by(Movie, tmdb_id: 372_058) == nil
      assert prepared.attrs.media_profile == :anime
      assert prepared.attrs.preferred_language == "french"

      assert {:ok, movie} =
               Catalog.find_or_create_at_requested(prepared.attrs, prepared.aliases)

      assert movie.media_profile == :anime
      assert [%{title: "Kimi no Na wa.", source: "tmdb"}] = Catalog.list_title_aliases(movie)
    end

    test "an existing movie short-circuits without provider I/O" do
      movie = movie_fixture(tmdb_id: 372_059)

      assert {:ok, %{attrs: attrs, aliases: []}} =
               Catalog.prepare_requested_movie(%{tmdb_id: movie.tmdb_id, title: "Ignored"})

      assert attrs.tmdb_id == movie.tmdb_id
    end

    test "a provider error writes neither movie nor aliases" do
      expect(Cinder.Catalog.TMDBMock, :get_movie, fn 372_060 ->
        {:ok, Map.put(@details, :tmdb_id, 372_060)}
      end)

      expect(Cinder.Catalog.TMDBMock, :get_movie_alternative_titles, fn 372_060 ->
        {:error, :timeout}
      end)

      assert {:error, :timeout} = Catalog.prepare_requested_movie(%{tmdb_id: 372_060})
      assert Repo.get_by(Movie, tmdb_id: 372_060) == nil
    end
  end

  describe "enrich_movie/1" do
    test "backfills descriptive metadata from TMDB details on first view" do
      movie = movie_fixture()
      details = Map.put(@details, :tmdb_id, movie.tmdb_id)

      expect(Cinder.Catalog.TMDBMock, :get_movie, fn tmdb_id ->
        assert tmdb_id == movie.tmdb_id
        {:ok, details}
      end)

      enriched = Catalog.enrich_movie(movie)

      assert enriched.overview =~ "thief"
      assert enriched.runtime == 148
      assert enriched.genres == ["Action", "Science Fiction"]
      assert enriched.vote_average == 8.4
      assert enriched.release_date == ~D[2010-07-16]

      # persisted, not just in memory
      assert Repo.get!(Movie, movie.id).overview =~ "thief"
    end

    test "refreshes an already-enriched movie" do
      movie = movie_fixture()
      details = Map.put(@details, :tmdb_id, movie.tmdb_id)

      expect(Cinder.Catalog.TMDBMock, :get_movie, 2, fn _ -> {:ok, details} end)

      enriched = Catalog.enrich_movie(movie)
      assert Catalog.enrich_movie(enriched) == enriched
    end

    test "returns the row unchanged when TMDB errors, so the page still renders" do
      movie = movie_fixture()
      expect(Cinder.Catalog.TMDBMock, :get_movie, fn _ -> {:error, :timeout} end)

      assert Catalog.enrich_movie(movie) == movie
      assert is_nil(Repo.get!(Movie, movie.id).vote_average)
    end

    test "preserves updated_at so a read (page view) doesn't reorder the Recent slice" do
      movie = movie_fixture()
      past = ~U[2020-01-01 00:00:00Z]

      {1, _} =
        Repo.update_all(from(m in Movie, where: m.id == ^movie.id), set: [updated_at: past])

      movie = Repo.get!(Movie, movie.id)

      details = Map.put(@details, :tmdb_id, movie.tmdb_id)
      expect(Cinder.Catalog.TMDBMock, :get_movie, fn _ -> {:ok, details} end)

      enriched = Catalog.enrich_movie(movie)

      assert enriched.overview =~ "thief", "metadata was still written"

      assert Repo.get!(Movie, movie.id).updated_at == past,
             "updated_at must not bump on a backfill"
    end

    test "does not restore a stale timestamp over a concurrent transition" do
      movie = movie_fixture()
      past = ~U[2020-01-01 00:00:00Z]

      {1, _} =
        Repo.update_all(from(m in Movie, where: m.id == ^movie.id), set: [updated_at: past])

      movie = Repo.get!(Movie, movie.id)
      details = Map.put(@details, :tmdb_id, movie.tmdb_id)
      test_pid = self()

      expect(Cinder.Catalog.TMDBMock, :get_movie, fn _ ->
        {:ok, transitioned} = Catalog.transition(movie, %{status: :downloading})
        send(test_pid, {:transitioned, transitioned.updated_at})
        {:ok, details}
      end)

      Catalog.enrich_movie(movie)

      assert_receive {:transitioned, transitioned_at}
      refreshed = Repo.get!(Movie, movie.id)
      assert refreshed.status == :downloading
      assert refreshed.updated_at == transitioned_at
      assert refreshed.overview =~ "thief"
    end
  end

  describe "enrich_series/1" do
    test "backfills series descriptive metadata via a get_series-only fetch" do
      series = series_fixture()

      expect(Cinder.Catalog.TMDBMock, :get_series, fn tmdb_id ->
        assert tmdb_id == series.tmdb_id

        {:ok,
         %{
           tmdb_id: series.tmdb_id,
           tvdb_id: nil,
           title: "Show",
           year: 2008,
           poster_path: nil,
           original_language: "en",
           overview: "A show about things.",
           genres: ["Drama"],
           vote_average: 7.7,
           first_air_date: ~D[2008-01-20],
           seasons: [%{season_number: 1}]
         }}
      end)

      enriched = Catalog.enrich_series(series)

      assert enriched.overview =~ "things"
      assert enriched.genres == ["Drama"]
      assert enriched.vote_average == 7.7
      assert enriched.first_air_date == ~D[2008-01-20]
      assert Repo.get!(Series, series.id).overview =~ "things"
    end
  end
end
