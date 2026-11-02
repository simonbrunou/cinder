defmodule Cinder.CatalogFixturesTest do
  # The fixtures build every catalog test's starting state, so a key they drop makes a test start
  # from a state other than the one it wrote (#849).
  use Cinder.DataCase, async: true

  alias Cinder.Catalog.{Events, Movie}

  import Cinder.CatalogFixtures

  describe "movie_fixture/1" do
    test "keeps the counters and the policy snapshot it is given" do
      snapshot = %{"min_seeders" => 3}

      movie =
        movie_fixture(%{
          status: :searching,
          search_attempts: 2,
          import_attempts: 1,
          release_policy_snapshot: snapshot
        })

      expected = [search_attempts: 2, import_attempts: 1, release_policy_snapshot: snapshot]

      for {key, value} <- expected do
        assert Map.fetch!(movie, key) == value
        assert Map.fetch!(Repo.get!(Movie, movie.id), key) == value
      end
    end

    test "keeps a creation key and the media profile next to pipeline keys" do
      movie =
        movie_fixture(%{
          title: "Arrival",
          imdb_id: "tt2543164",
          media_profile: :anime,
          status: :available,
          file_path: "/lib/a.mkv"
        })

      assert %Movie{
               title: "Arrival",
               imdb_id: "tt2543164",
               media_profile: :anime,
               status: :available,
               file_path: "/lib/a.mkv"
             } = Repo.get!(Movie, movie.id)
    end

    test "keeps download metrics passed with an active download status" do
      movie =
        movie_fixture(%{
          status: :downloading,
          download_progress: 0.5,
          download_speed: 1024,
          download_eta: 60
        })

      assert %Movie{download_progress: 0.5, download_speed: 1024, download_eta: 60} =
               Repo.get!(Movie, movie.id)
    end

    test "keeps a failure reason passed with :import_failed" do
      movie = movie_fixture(%{status: :import_failed, failure_reason: "no video file"})

      assert %Movie{failure_reason: "no video file"} = Repo.get!(Movie, movie.id)
    end

    test "raises on a key nothing accepts, naming it, and creates no row" do
      assert_raise ArgumentError, ~r/:no_such_key/, fn -> movie_fixture(%{no_such_key: 1}) end
      assert Repo.aggregate(Movie, :count) == 0
    end

    test "raises on a string key, naming it" do
      assert_raise ArgumentError, ~r/"title"/, fn -> movie_fixture(%{"title" => "Arrival"}) end
    end

    test "raises on a blank value cast/3 would empty, naming the key" do
      assert_raise ArgumentError, ~r/:overview/, fn -> movie_fixture(%{overview: ""}) end

      assert_raise ArgumentError, ~r/:download_id/, fn ->
        movie_fixture(%{status: :downloading, download_id: ""})
      end

      assert_raise ArgumentError, ~r/:part_file_paths/, fn ->
        movie_fixture(%{status: :available, part_file_paths: ["/lib/a-cd1.mkv", " "]})
      end

      assert_raise ArgumentError, ~r/:media_profile/, fn ->
        movie_fixture(%{media_profile: ""})
      end

      assert Repo.aggregate(Movie, :count) == 0
    end

    test "raises on a nil media profile, naming it, and creates no row" do
      assert_raise ArgumentError, ~r/:media_profile/, fn ->
        movie_fixture(%{media_profile: nil})
      end

      assert Repo.aggregate(Movie, :count) == 0
    end

    test "raises on a nil media profile next to a pipeline key before any write or broadcast" do
      :ok = Events.subscribe_movies()
      tmdb_id = System.unique_integer([:positive])

      assert_raise ArgumentError, ~r/:media_profile/, fn ->
        movie_fixture(%{tmdb_id: tmdb_id, media_profile: nil, status: :searching})
      end

      assert Repo.aggregate(Movie, :count) == 0
      # The topic is global, so only a broadcast for this call's movie counts.
      refute_receive {:movie_updated, %Movie{tmdb_id: ^tmdb_id}}
    end

    test "raises on a nil for any NOT NULL column, naming the key, and creates no row" do
      for key <- [:status, :search_attempts, :part_file_paths, :preferred_language, :title] do
        assert_raise ArgumentError, ~r/#{inspect(key)}/, fn -> movie_fixture(%{key => nil}) end
      end

      assert Repo.aggregate(Movie, :count) == 0
    end

    test "names every passed nil key whose column is NOT NULL in one raise" do
      error =
        assert_raise ArgumentError, fn ->
          movie_fixture(%{media_profile: nil, status: nil, imdb_id: nil})
        end

      assert error.message =~ ":media_profile"
      assert error.message =~ ":status"
      refute error.message =~ ":imdb_id"
    end

    test "keeps a nil for a nullable column" do
      assert %Movie{imdb_id: nil} = movie_fixture(%{imdb_id: nil})

      # `localizations` defaults to %{}, so only its nil shows the value was kept, not dropped.
      movie =
        movie_fixture(%{
          localizations: nil,
          status: :available,
          file_path: nil,
          content_path: nil,
          imported_resolution: nil
        })

      assert %Movie{
               localizations: nil,
               file_path: nil,
               content_path: nil,
               imported_resolution: nil
             } = Repo.get!(Movie, movie.id)
    end

    test "raises on a passed value the status would clear, naming the key" do
      assert_raise ArgumentError, ~r/:download_progress/, fn ->
        movie_fixture(%{status: :searching, download_progress: 0.5})
      end

      assert_raise ArgumentError, ~r/:failure_reason/, fn ->
        movie_fixture(%{failure_reason: "no video file"})
      end
    end
  end
end
