defmodule Cinder.CatalogTest do
  use Cinder.DataCase, async: true

  import Cinder.CatalogFixtures
  import ExUnit.CaptureLog
  import Mox

  alias Cinder.Catalog
  alias Cinder.Catalog.{BlockedRelease, Episode, Grab, Movie, Season, Series}

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
      {:ok, movie} = Catalog.add_movie(%{tmdb_id: 1, title: "M"})
      Catalog.subscribe()

      assert {:ok, %Movie{status: :downloading, download_id: "h"}} =
               Catalog.transition(movie, %{status: :downloading, download_id: "h"})

      assert_receive {:movie_updated, %Movie{id: id, status: :downloading}}
      assert id == movie.id
    end

    test "transition/2 rejects an unknown status" do
      {:ok, movie} = Catalog.add_movie(%{tmdb_id: 2, title: "M"})

      assert {:error, changeset} = Catalog.transition(movie, %{status: :bogus})
      assert %{status: ["is invalid"]} = errors_on(changeset)
    end

    test "transition/2 accepts :cancelled as a valid status" do
      {:ok, movie} = Catalog.add_movie(%{tmdb_id: 4242, title: "M"})

      assert {:ok, %Movie{status: :cancelled}} =
               Catalog.transition(movie, %{status: :cancelled})
    end

    test "transition/3 with expect: writes only when the DB status still matches" do
      {:ok, movie} = Catalog.add_movie(%{tmdb_id: 4243, title: "M"})
      {:ok, searching} = Catalog.transition(movie, %{status: :searching})

      assert {:ok, %Movie{status: :downloading}} =
               Catalog.transition(searching, %{status: :downloading, download_id: "h"},
                 expect: :searching
               )
    end

    test "transition/3 with expect: skips a stale write (poller vs user-cancel race)" do
      {:ok, movie} = Catalog.add_movie(%{tmdb_id: 4244, title: "M"})
      {:ok, searching} = Catalog.transition(movie, %{status: :searching})

      # The user cancels while the poller's unit is in flight with the :searching struct…
      {:ok, _} = Catalog.transition(searching, %{status: :cancelled})

      # …so the poller's write-back misses and the cancel stands.
      assert {:error, :stale_status} =
               Catalog.transition(searching, %{status: :downloading, download_id: "h"},
                 expect: :searching
               )

      assert Repo.get!(Movie, movie.id).status == :cancelled
    end

    test "guarded transition broadcasts exactly once and a stale guard stays silent" do
      {:ok, movie} = Catalog.add_movie(%{tmdb_id: 4245, title: "M"})
      Catalog.subscribe()

      {:ok, searching} = Catalog.transition(movie, %{status: :searching})
      assert_receive {:movie_updated, %Movie{id: id, status: :searching}}
      assert id == movie.id

      assert {:ok, %Movie{status: :downloading}} =
               Catalog.transition(searching, %{status: :downloading, download_id: "guarded"},
                 expect: :searching
               )

      assert_receive {:movie_updated, %Movie{id: ^id, status: :downloading}}
      refute_receive {:movie_updated, %Movie{id: ^id}}

      assert {:error, :stale_status} =
               Catalog.transition(searching, %{status: :downloaded}, expect: :searching)

      refute_receive {:movie_updated, %Movie{id: ^id}}
      assert Repo.get!(Movie, id).status == :downloading
    end

    test "transition/2 persists file_path" do
      {:ok, movie} = Catalog.add_movie(%{tmdb_id: 9001, title: "Heat"})

      assert {:ok, %Movie{file_path: "/downloads/Heat.1995.mkv"}} =
               Catalog.transition(movie, %{
                 status: :downloaded,
                 file_path: "/downloads/Heat.1995.mkv"
               })

      assert %Movie{file_path: "/downloads/Heat.1995.mkv"} = Repo.get!(Movie, movie.id)
    end

    test "list_by_status/1 returns only movies in that status" do
      {:ok, _a} = Catalog.add_movie(%{tmdb_id: 4, title: "A"})
      {:ok, b} = Catalog.add_movie(%{tmdb_id: 5, title: "B"})
      {:ok, _} = Catalog.transition(b, %{status: :downloading, download_id: "h"})

      assert [%Movie{tmdb_id: 5}] = Catalog.list_by_status(:downloading)
      assert [%Movie{tmdb_id: 4}] = Catalog.list_by_status(:requested)
    end
  end

  describe "list_available_movies_with_file/0, list_episodes_with_file/0" do
    test "list_available_movies_with_file/0 returns only :available movies with a file_path" do
      m1 = movie_fixture(status: :available, file_path: "/x/a.mkv")
      _m2 = movie_fixture(status: :available, file_path: nil)
      _m3 = movie_fixture(status: :requested, file_path: "/x/c.mkv")

      ids = Catalog.list_available_movies_with_file() |> Enum.map(& &1.id)
      assert ids == [m1.id]
    end

    test "list_episodes_with_file/0 returns episodes with a file_path, season+series preloaded" do
      series = series_fixture()
      season = season_fixture(series)
      ep = episode_fixture(season, file_path: "/x/e.mkv")
      _no_file = episode_fixture(season, episode_number: 2, file_path: nil)

      assert [got] = Catalog.list_episodes_with_file()
      assert got.id == ep.id
      assert %Series{} = got.season.series
    end
  end

  describe "retry_movie/1" do
    test "resets a parked movie to :requested, zeroes attempt counters, and broadcasts" do
      Catalog.subscribe()

      for {tmdb_id, parked} <- [{8001, :no_match}, {8002, :search_failed}, {8003, :import_failed}] do
        {:ok, movie} = Catalog.add_movie(%{tmdb_id: tmdb_id, title: "M"})

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
      {:ok, movie} = Catalog.add_movie(%{tmdb_id: 8100, title: "M"})
      {:ok, downloading} = Catalog.transition(movie, %{status: :downloading, download_id: "h"})

      assert {:error, :not_retryable} = Catalog.retry_movie(downloading)
      assert Catalog.get_movie_by_id(movie.id).status == :downloading
    end

    test "preserves the blocklist row while clearing release_title on re-queue" do
      {:ok, movie} = Catalog.add_movie(%{tmdb_id: 8200, title: "M"})

      {:ok, movie} =
        Catalog.transition(movie, %{status: :import_failed, release_title: "Bad.Release.1080p"})

      :ok = Catalog.block_release(movie, :wrong_audio_language)

      assert {:ok, %Movie{status: :requested, release_title: nil}} = Catalog.retry_movie(movie)
      # The blocklist row survives the retry, keyed by movie_id (clearing it would re-grab).
      assert Catalog.blocked_release_titles(movie) == ["Bad.Release.1080p"]
    end
  end

  describe "get_movie_by_id/1" do
    test "returns the movie by primary key, or nil" do
      {:ok, movie} = Catalog.add_movie(%{tmdb_id: 7001, title: "M"})
      assert %Cinder.Catalog.Movie{id: id} = Catalog.get_movie_by_id(movie.id)
      assert id == movie.id
      assert Catalog.get_movie_by_id(-1) == nil
    end
  end

  describe "search_failed terminal + search_attempts" do
    test "transition can set :search_failed and persist search_attempts" do
      {:ok, movie} = Catalog.add_movie(%{tmdb_id: 7002, title: "M"})
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
      {:ok, movie} = Catalog.add_movie(@attrs)
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

    test "an existing :auto movie approved as Anime with a non-default pick adopts it (fill-if-default)" do
      {:ok, movie} = Catalog.add_movie(@attrs)
      assert movie.media_profile == :auto
      assert movie.preferred_language == "original"

      attrs = Map.merge(@attrs, %{media_profile: :anime, preferred_language: "french"})
      assert {:ok, updated} = Catalog.find_or_create_at_requested(attrs)
      assert updated.media_profile == :anime
      assert updated.preferred_language == "french"
    end

    test "an already-Anime movie's Audio pick is release policy — a later request pick never fills it" do
      {:ok, movie} = Catalog.add_movie(@attrs)
      {:ok, _movie} = Catalog.set_media_profile(movie, :anime)

      attrs = Map.merge(@attrs, %{media_profile: :anime, preferred_language: "french"})
      assert {:ok, updated} = Catalog.find_or_create_at_requested(attrs)
      assert updated.preferred_language == "original"
    end

    test "an existing standard movie fills the pick only if it was still default (fill-if-default)" do
      {:ok, movie} = Catalog.add_movie(@attrs)
      {:ok, _movie} = Catalog.set_media_profile(movie, :standard)

      attrs = Map.merge(@attrs, %{media_profile: :standard, preferred_language: "french"})
      assert {:ok, updated} = Catalog.find_or_create_at_requested(attrs)
      assert updated.preferred_language == "french"
    end

    test "an existing standard movie already customized keeps its pick against a later request" do
      {:ok, movie} = Catalog.add_movie(@attrs)
      {:ok, movie} = Catalog.set_media_profile(movie, :standard)
      {:ok, _movie} = Catalog.set_movie_language(movie, "any")

      attrs = Map.merge(@attrs, %{media_profile: :standard, preferred_language: "french"})
      assert {:ok, updated} = Catalog.find_or_create_at_requested(attrs)
      assert updated.preferred_language == "any"
    end
  end

  describe "add_movie/1 and list_movies/0" do
    @attrs %{tmdb_id: 27_205, title: "Inception", year: 2010, poster_path: "/p.jpg"}

    test "persists a movie as :requested and lists it" do
      assert {:ok, %Movie{} = movie} = Catalog.add_movie(@attrs)
      assert movie.tmdb_id == 27_205
      assert movie.title == "Inception"
      assert movie.status == :requested

      assert [%Movie{tmdb_id: 27_205, status: :requested}] = Catalog.list_movies()
    end

    test "accepts a movie with a nil year and poster_path" do
      attrs = %{tmdb_id: 1, title: "Obscure", year: nil, poster_path: nil}
      assert {:ok, %Movie{year: nil, poster_path: nil}} = Catalog.add_movie(attrs)
    end

    test "rejects a duplicate tmdb_id" do
      assert {:ok, _} = Catalog.add_movie(@attrs)
      assert {:error, changeset} = Catalog.add_movie(@attrs)
      assert %{tmdb_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "requires tmdb_id and title" do
      assert {:error, changeset} = Catalog.add_movie(%{})
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
      {:ok, movie} = Catalog.add_movie(%{tmdb_id: 7, title: "X"})
      {:ok, movie} = Catalog.transition(movie, %{status: :no_match})

      {:ok, updated} = Catalog.set_movie_language(movie, "french")

      assert updated.preferred_language == "french"
      assert updated.status == :requested
      assert updated.search_attempts == 0
    end

    test "re-queues a search_failed movie" do
      {:ok, movie} = Catalog.add_movie(%{tmdb_id: 9, title: "Z"})
      {:ok, movie} = Catalog.transition(movie, %{status: :search_failed})

      {:ok, updated} = Catalog.set_movie_language(movie, "french")

      assert updated.preferred_language == "french"
      assert updated.status == :requested
      assert updated.search_attempts == 0
    end

    test "on an available movie only updates the field" do
      {:ok, movie} = Catalog.add_movie(%{tmdb_id: 8, title: "Y"})
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

      grab = Repo.insert!(%Grab{download_id: "dl1", download_protocol: :torrent})

      in_flight =
        Repo.insert!(%Episode{
          season_id: season.id,
          episode_number: 3,
          monitored: true,
          search_attempts: 9,
          grab_id: grab.id
        })

      {:ok, updated} = Catalog.set_series_language(series, "french")

      assert updated.preferred_language == "french"
      assert Repo.get!(Episode, wanted.id).search_attempts == 0
      assert Repo.get!(Episode, filed.id).search_attempts == 9
      assert Repo.get!(Episode, in_flight.id).search_attempts == 9
    end
  end

  describe "release blocklist" do
    test "block_release/2 + blocked_release_titles/1 round-trip" do
      movie = Repo.insert!(%Movie{tmdb_id: 9001, title: "M", release_title: "Bad.Release.1080p"})

      assert :ok = Catalog.block_release(movie, :wrong_audio_language)
      assert Catalog.blocked_release_titles(movie) == ["Bad.Release.1080p"]
    end

    test "block_release/2 is a no-op on a nil release_title" do
      movie = Repo.insert!(%Movie{tmdb_id: 9002, title: "M", release_title: nil})

      assert :ok = Catalog.block_release(movie, :no_match)
      assert Catalog.blocked_release_titles(movie) == []
      assert Repo.all(BlockedRelease) == []
    end

    test "block writers are non-raising on a forced insert error" do
      # movie_id 999_999 has no movies row → an FK violation raises, which the writer catches:
      # it logs, returns :ok, and inserts nothing.
      ghost = %Movie{id: 999_999, release_title: "Ghost.Release"}

      log = capture_log(fn -> assert :ok = Catalog.block_release(ghost, :download_error) end)

      assert log =~ "block_release raised:"
      assert log =~ "foreign_key_constraint"
      assert Repo.all(BlockedRelease) == []
    end

    test "block_grab_release/2 scopes the block to the grab's series" do
      series = Repo.insert!(%Series{tmdb_id: 9003, title: "S"})
      season = Repo.insert!(%Season{series_id: series.id, season_number: 1, monitored: true})
      ep = Repo.insert!(%Episode{season_id: season.id, episode_number: 1, monitored: true})

      {:ok, grab} = Catalog.create_grab("H", :torrent, [ep.id], "Pack.S01.720p")

      assert :ok = Catalog.block_grab_release(grab, :no_files_matched)
      assert Catalog.blocked_release_titles_for_series(series.id) == ["Pack.S01.720p"]
    end
  end

  describe "manual_grab_movie/2" do
    setup do
      release = %Cinder.Acquisition.Release{
        title: "Pick",
        protocol: :torrent,
        download_url: "magnet:?x"
      }

      %{release: release}
    end

    test "an available movie goes :upgrading, preserving its file", %{release: release} do
      movie =
        movie_fixture(
          status: :available,
          file_path: "/lib/Movie (2020)/Movie (2020).mkv",
          imported_resolution: "1080p"
        )

      Cinder.Download.ClientMock |> expect(:add, fn _, _opts -> {:ok, "dl-9"} end)

      assert {:ok, up} = Catalog.manual_grab_movie(movie, release)
      assert up.status == :upgrading
      assert up.download_id == "dl-9"
      assert up.release_title == "Pick"
      assert up.file_path == "/lib/Movie (2020)/Movie (2020).mkv"
      assert up.imported_resolution == "1080p"
    end

    test "a parked movie goes :downloading", %{release: release} do
      movie = movie_fixture(status: :no_match)
      Cinder.Download.ClientMock |> expect(:add, fn _, _opts -> {:ok, "dl-7"} end)
      assert {:ok, dl} = Catalog.manual_grab_movie(movie, release)
      assert dl.status == :downloading
    end

    test "an in-flight movie is rejected", %{release: release} do
      movie = movie_fixture(status: :downloading)
      assert Catalog.manual_grab_movie(movie, release) == {:error, :not_grabbable}
    end

    test "a movie deleted mid-action is rejected before add and returns :stale_entry",
         %{release: release} do
      movie = movie_fixture(status: :no_match)
      Repo.delete!(movie)

      assert Catalog.manual_grab_movie(movie, release) == {:error, :stale_entry}
    end
  end

  describe "abort_upgrade/2" do
    test "reverts an :upgrading movie to :available and removes the download" do
      movie =
        movie_fixture(
          status: :upgrading,
          download_id: "dl-3",
          download_protocol: :torrent,
          file_path: "/lib/M (2020)/M (2020).mkv"
        )

      Cinder.Download.ClientMock |> expect(:remove, fn "dl-3", _ -> :ok end)
      assert {:ok, reverted} = Catalog.abort_upgrade(movie, nil)
      assert reverted.status == :available
      assert reverted.download_id == nil
      assert reverted.file_path == "/lib/M (2020)/M (2020).mkv"
    end

    test "rejects a non-upgrading movie" do
      assert Catalog.abort_upgrade(movie_fixture(status: :available), nil) ==
               {:error, :not_upgrading}
    end
  end

  test "delete_movie removes the in-flight download of an :upgrading movie" do
    movie =
      movie_fixture(status: :upgrading, download_id: "dl-4", download_protocol: :torrent)

    Cinder.Download.ClientMock |> expect(:remove, fn "dl-4", _ -> :ok end)
    assert {:ok, _} = Catalog.delete_movie(movie, nil)
  end
end
