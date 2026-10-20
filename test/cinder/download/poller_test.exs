defmodule Cinder.Download.PollerTest do
  @moduledoc """
  The movie poller's own job: mapping each `Cinder.Download.Watch` verdict, each
  `Cinder.Library.stage_movie/2` result and each `Cinder.Download.start/1` result onto the right
  `Cinder.Catalog.MovieLifecycle` verb, the holds it decides itself, and recovery.

  What a verb then does to the movie is pinned in `MovieLifecycleTest`, the verdicts in
  `WatchTest`, the staging in `StagedImportTest` and `LibraryTest`, and the search in
  `DownloadTest` and `AnimeMovieSearchTest`.
  """
  use Cinder.DataCase, async: false

  import ExUnit.CaptureLog
  import Mox

  # The poller logs warnings/errors on the import failure paths exercised below;
  # capture them so test output stays pristine (they print on failure).
  @moduletag :capture_log

  alias Cinder.Catalog
  alias Cinder.Catalog.{BlockedRelease, Movie, MovieLifecycle}
  alias Cinder.Download.{Intent, Poller, StallReaper, TvPoller}
  alias Cinder.Library.ImportStage
  alias Cinder.Repo

  import Cinder.CatalogFixtures
  import Cinder.ConfigCase
  import Cinder.LibraryStubs
  import Cinder.PollerHelpers

  # The poller runs in its own process (and a fresh pid after a crash), so the
  # mock must be global. Shared Sandbox (async: false) lets those processes use
  # the test-owned DB connection.
  setup :set_mox_global

  # An `expect` the poller never reaches fails the test. An extra call still raises inside the
  # poller's `isolate/2`, which only logs it, so a test that must rule a call out spies on it
  # with `send` and `refute_received`.
  setup :verify_on_exit!

  # A poll stamps last-run into process-global :persistent_term (PollerSkeleton's `status/0`,
  # read by /healthz); erase it so a recorded run can't bleed into another test/suite.
  setup do
    on_exit(fn ->
      :persistent_term.erase({Poller, :last_run})
      :persistent_term.erase({TvPoller, :last_run})
    end)

    stub_clean_content()
  end

  defp downloading_movie(tmdb_id, download_id, extra \\ []) do
    movie_fixture(
      Enum.into(extra, %{
        tmdb_id: tmdb_id,
        title: "M",
        status: :downloading,
        download_id: download_id
      })
    )
  end

  defp downloaded_movie(tmdb_id, file_path) do
    movie_fixture(%{
      tmdb_id: tmdb_id,
      title: "Inception",
      year: 2010,
      status: :downloaded,
      file_path: file_path
    })
  end

  # One strike short of its failure budget. A test asserting that the poller takes no strike
  # starts here, so a verdict that leaked into `MovieLifecycle.record_failure/2` would park it
  # (or revert it, for an upgrade).
  defp last_strike(movie) do
    {:ok, movie} = seed_movie_state(movie, %{import_attempts: 9})
    movie
  end

  # Drives the free-disk prober (Cinder.Test.StubDisk) for a test's duration: `result` is a
  # `{:ok, stats}` / `{:error, reason}` tuple returned for every path.
  defp set_disk_stub!(result), do: put_env(:disk_stats_stub, result)

  describe "download watch verdicts:" do
    test "a completed download is marked downloaded, then imported in the same tick" do
      movie = downloading_movie(1, "hash-1")
      Catalog.subscribe()
      start_supervised!({Poller, interval: 60_000})

      stub(Cinder.Download.ClientMock, :status, fn "hash-1" ->
        {:ok, %{state: :completed, content_path: "/downloads/M.mkv"}}
      end)

      stub_import_ok()

      assert :ok = Poller.poll()

      assert %Movie{status: :available} = Repo.get!(Movie, movie.id)
      # Passes through :downloaded (pass 1) then :available (pass 2) in one tick.
      assert_receive {:movie_updated, %Movie{status: :downloaded}}
      assert_receive {:movie_updated, %Movie{status: :available}}
    end

    test "a completed upgrade imports via forced replace and ends :available with new quality" do
      movie =
        movie_fixture(%{
          tmdb_id: 70,
          status: :upgrading,
          download_id: "dl-1",
          download_protocol: :torrent,
          release_title: "Better.1080p-GRP",
          file_path: "/lib/M (2020)/M (2020).mkv",
          imported_resolution: "720p"
        })

      start_supervised!({Poller, interval: 60_000})

      expect(Cinder.Download.ClientMock, :status, fn "dl-1" ->
        {:ok, %{state: :completed, content_path: "/dl/Better.1080p.mkv"}}
      end)

      # The canonical library dest already holds the live file; lstat returns the same inode for
      # source and dest, so staging finds the same file there — `replace: true` forces the NEW
      # quality ("1080p") to be recorded (without the forced replace it would keep the stale
      # "720p", so asserting "1080p" proves the forced replace). The old file at a DIFFERENT path is
      # removed best-effort after the swap.
      test_pid = self()
      stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)

      stub(Cinder.Library.FilesystemMock, :lstat, fn path ->
        if staging_path?(path),
          do: {:error, :enoent},
          else: {:ok, %File.Stat{type: :regular, size: 1, inode: 1}}
      end)

      stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
      stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> {:error, :eexist} end)

      stub(Cinder.Library.FilesystemMock, :rm, fn path ->
        send(test_pid, {:rm, path})
        :ok
      end)

      stub(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)

      assert :ok = Poller.poll()

      reloaded = Repo.get!(Movie, movie.id)
      assert reloaded.status == :available
      assert reloaded.imported_resolution == "1080p"

      # the live pointer moved to the new library dest (it was never overwritten with content_path)
      assert reloaded.file_path =~ "/tmp/cinder-test-library"
      refute reloaded.file_path == "/lib/M (2020)/M (2020).mkv"
      # the old file (different container path) is unlinked best-effort after the DB commit
      assert_receive {:rm, "/lib/M (2020)/M (2020).mkv"}
    end

    test "a download still in flight takes no strike" do
      movie = last_strike(downloading_movie(2, "hash-2"))
      start_supervised!({Poller, interval: 60_000})

      stub(Cinder.Download.ClientMock, :status, fn "hash-2" ->
        {:ok, %{state: :downloading, progress: 0.42}}
      end)

      assert :ok = Poller.poll()

      # The progress shows the tick reached the watch.
      assert %Movie{status: :downloading, import_attempts: 9, download_progress: 0.42} =
               Repo.get!(Movie, movie.id)
    end

    # A slow or restarting client is no evidence about the download.
    test "a client that cannot answer costs no strike" do
      movie = last_strike(downloading_movie(7, "hash-7"))

      {:ok, movie} =
        MovieLifecycle.track(movie, %{download_progress: 0.42, download_speed: 1_000})

      start_supervised!({Poller, interval: 60_000})
      stub(Cinder.Download.ClientMock, :status, fn "hash-7" -> {:error, :timeout} end)

      assert :ok = Poller.poll()

      # The cleared speed shows the tick reached the watch.
      assert %Movie{status: :downloading, import_attempts: 9, download_speed: nil} =
               Repo.get!(Movie, movie.id)
    end

    # The client's own error text (SABnzbd's paused state, say) goes to the log; the notification
    # keeps the classifying code, and the movie goes back to :requested for another try.
    test "a download the client reports failed is blocklisted and re-queued on its last strike" do
      Cinder.TestNotifier.subscribe()

      movie =
        movie_fixture(%{
          tmdb_id: 88,
          status: :downloading,
          download_id: "hash-paused",
          download_protocol: :torrent,
          release_title: "Paused.Release.1080p"
        })

      # The lifecycle tolerates two client failures; this tick's is the third.
      {:ok, movie} = seed_movie_state(movie, %{import_attempts: 2})

      stub(Cinder.Download.ClientMock, :status, fn "hash-paused" ->
        {:ok, %{state: :error, reason: "Paused by the download client (duplicate detection)"}}
      end)

      stub(Cinder.Download.ClientMock, :remove, fn "hash-paused", _opts -> :ok end)

      start_supervised!({Poller, interval: 60_000})
      assert :ok = Poller.poll()

      assert %Movie{status: :requested} = Repo.get!(Movie, movie.id)
      assert Catalog.blocked_release_titles(movie) == ["Paused.Release.1080p"]
      assert_receive {:notify, {:movie_failed, %Movie{status: :requested}, :download_error}}
    end

    test "a download with no client for its protocol parks on its last strike" do
      # Drop usenet from the client map so a usenet movie's status poll can't resolve a client.
      put_env(:download_clients, %{torrent: Cinder.Download.ClientMock})

      movie =
        last_strike(
          movie_fixture(%{
            tmdb_id: 21,
            title: "M",
            status: :downloading,
            download_id: "nzo-21",
            download_protocol: :usenet,
            release_title: "Good.Release-GRP"
          })
        )

      start_supervised!({Poller, interval: 60_000})

      assert :ok = Poller.poll()
      assert %Movie{status: :import_failed} = Repo.get!(Movie, movie.id)
      # A missing client is a config glitch, not evidence against the release.
      assert Catalog.blocked_release_titles(movie) == []
    end

    test "a stalled download is removed with its data, blocklisted and re-queued" do
      put_config(StallReaper, enabled: true, stall_timeout: 0, no_seeders_timeout: 0)

      movie =
        movie_fixture(%{
          tmdb_id: 71,
          title: "M",
          status: :downloading,
          download_id: "hash-stall",
          download_protocol: :torrent,
          release_title: "Dead.Release.1080p"
        })

      test_pid = self()

      stub(Cinder.Download.ClientMock, :status, fn "hash-stall" ->
        {:ok, %{state: :downloading, progress: 0.0, speed: 0, seeders: 0}}
      end)

      stub(Cinder.Download.ClientMock, :remove, fn id, opts ->
        send(test_pid, {:removed, id, opts})
        :ok
      end)

      start_supervised!({Poller, interval: 60_000})
      assert :ok = Poller.poll()

      reaped = Repo.get!(Movie, movie.id)
      assert reaped.status == :requested
      assert reaped.download_id == nil
      assert reaped.download_protocol == nil
      assert reaped.release_title == nil
      assert reaped.search_attempts == 1
      assert Catalog.blocked_release_titles(reaped) == ["Dead.Release.1080p"]

      assert_receive {:removed, "hash-stall", opts}
      assert Keyword.get(opts, :delete_files) == true
    end

    test "a fake payload re-queues on the first tick, blocklisted" do
      movie = downloading_movie(90, "hash-fake", release_title: "Movie.2024.1080p-FAKE")

      stub(Cinder.Download.ClientMock, :status, fn "hash-fake" ->
        {:ok, %{state: :downloading, progress: 0.9, speed: 500_000, seeders: 40}}
      end)

      expect(Cinder.Download.ClientMock, :files, fn "hash-fake" ->
        {:ok, ["Movie.2024.1080p/Movie.2024.1080p.mkv.lnk", "Movie.2024.1080p/readme.txt"]}
      end)

      stub(Cinder.Download.ClientMock, :remove, fn "hash-fake", _opts -> :ok end)

      start_supervised!({Poller, interval: 60_000})
      assert :ok = Poller.poll()

      # :requested, not a bounded retry — the file list won't improve, so there is nothing to wait
      # for. import_attempts stays 0: this never entered `MovieLifecycle.record_failure/2`'s
      # client-failure tolerance.
      assert %Movie{status: :requested, import_attempts: 0, download_id: nil} =
               Repo.get!(Movie, movie.id)

      assert [%{release_title: "Movie.2024.1080p-FAKE", reason: "blocked_content"}] =
               Repo.all(BlockedRelease)
    end
  end

  describe "staged import results:" do
    # Doubles as the import-pass crash-recovery proof: a movie already stranded at
    # :downloaded (crash after download, before import) is imported on a later poll.
    test "a :downloaded movie is imported into the library and marked :available" do
      movie = downloaded_movie(10, "/downloads/Inception.2010.1080p.mkv")
      Catalog.subscribe()
      start_supervised!({Poller, interval: 60_000})

      test_pid = self()
      stub_import_ok()

      stub(Cinder.Library.FilesystemMock, :ln, fn _src, dest ->
        send(test_pid, {:linked, dest})
        :ok
      end)

      assert :ok = Poller.poll()
      assert %Movie{status: :available} = Repo.get!(Movie, movie.id)
      assert_receive {:movie_updated, %Movie{status: :available}}

      # After import, file_path must point at the LIBRARY destination (the imported hardlink),
      # not the download source — else delete_files unlinks the download copy and strands the
      # library file on disk.
      assert_receive {:linked, staged_path}
      assert candidate_path?(staged_path)
      assert %Movie{file_path: dest} = Repo.get!(Movie, movie.id)
      refute dest == "/downloads/Inception.2010.1080p.mkv"
    end

    test "a confirmed movie policy mismatch blocks only that title and grabs its sibling" do
      put_env(:media_info, Cinder.Library.MediaInfoMock)
      source = "/downloads/Anime.Movie.mkv"
      sibling_title = "[Group] Anime Movie v2 [1080p]"

      movie =
        movie_fixture(%{
          title: "Anime Movie",
          year: 2026,
          imdb_id: "tt-policy-mismatch",
          media_profile: :anime,
          original_language: "ja",
          status: :downloaded,
          download_id: "hash-policy-old",
          download_protocol: :torrent,
          release_title: "[Group] Anime Movie [1080p]",
          file_path: source
        })

      {:ok, movie} =
        seed_movie_state(movie, %{
          release_policy_snapshot: %{
            "version" => 1,
            "required_audio_languages" => ["ja", "fr"],
            "required_embedded_subtitle_languages" => [],
            "release_group" => "group",
            "release_title" => movie.release_title
          },
          search_attempts: 2,
          import_attempts: 3
        })

      expect(Cinder.Library.FilesystemMock, :dir?, fn ^source -> false end)

      expect(Cinder.Library.MediaInfoMock, :probe_policy, fn ^source ->
        {:ok, %{audio: ["ja"], subtitles: [], audio_unknown?: false, subtitle_unknown?: false}}
      end)

      expect(Cinder.Download.ClientMock, :remove, fn "hash-policy-old", delete_files: true ->
        :ok
      end)

      releases = [
        %{
          title: movie.release_title,
          size: 2_000_000_000,
          download_url: "magnet:?old"
        },
        %{title: sibling_title, size: 2_000_000_000, download_url: "magnet:?sibling"}
      ]

      stub(Cinder.Acquisition.IndexerMock, :search, fn _imdb_id -> {:ok, releases} end)

      stub(Cinder.Acquisition.IndexerMock, :search_movie_query, fn _query, categories: [5070] ->
        {:ok, releases}
      end)

      selected = start_supervised!({Agent, fn -> nil end})

      expect(Cinder.Download.ClientMock, :add, fn release, _opts ->
        Agent.update(selected, fn _ -> release.title end)
        {:ok, "hash-policy-sibling"}
      end)

      # The rejected movie is re-searched in the same tick: search runs after import.
      start_supervised!({Poller, interval: 60_000, search_retry_after: 0})
      assert :ok = Poller.poll()

      assert Agent.get(selected, & &1) == sibling_title

      assert %Movie{
               status: :downloading,
               download_id: "hash-policy-sibling",
               release_title: ^sibling_title,
               search_attempts: 2,
               import_attempts: 0
             } = Repo.get!(Movie, movie.id)

      assert Catalog.blocked_release_titles(movie) == [movie.release_title]
      refute Repo.exists?(ImportStage)
    end

    test "a failed import takes a strike and leaves the movie :downloaded for retry" do
      movie = downloaded_movie(11, "/downloads/Inception.2010.1080p.mkv")
      start_supervised!({Poller, interval: 60_000})

      stub_import_ok()

      stub(Cinder.Library.FilesystemMock, :lstat, fn path ->
        if candidate_path?(path), do: {:error, :enoent}, else: import_lstat(path, 1)
      end)

      stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> {:error, :eacces} end)

      assert :ok = Poller.poll()
      # :eacces (e.g. a read-only mount) is transient — stays :downloaded for retry.
      assert %Movie{status: :downloaded, import_attempts: 1} = Repo.get!(Movie, movie.id)
    end
  end

  # A downloaded file waiting on something the operator can fix: the poller holds it without a
  # strike, rather than spending the import budget on a condition retrying cannot change.
  describe "holds:" do
    test "an unconfigured movies library holds a downloaded movie" do
      movie = last_strike(downloaded_movie(79, "/downloads/held.mkv"))
      put_env(:movies_library_path, nil)
      start_supervised!({Poller, interval: 60_000})

      log = capture_log(fn -> assert :ok = Poller.poll() end)

      assert %Movie{status: :downloaded, import_attempts: 9} = Repo.get!(Movie, movie.id)
      assert log =~ "movies_library_path not set"
    end

    test "missing download roots hold a downloaded movie" do
      movie = last_strike(downloaded_movie(401, "/downloads/held.mkv"))
      put_env(:import_roots, [])
      start_supervised!({Poller, interval: 60_000})

      log = capture_log(fn -> assert :ok = Poller.poll() end)

      assert %Movie{status: :downloaded, import_attempts: 9} = Repo.get!(Movie, movie.id)
      assert log =~ "download import roots not configured"
      refute log =~ movie.file_path
    end

    test "missing download roots hold a completed upgrade without consuming attempts or metadata" do
      movie =
        last_strike(
          movie_fixture(%{
            tmdb_id: 69,
            status: :upgrading,
            download_id: "dl-roots",
            download_protocol: :torrent,
            release_title: "Better.1080p-GRP",
            file_path: "/lib/M (2020)/M (2020).mkv"
          })
        )

      assert {:ok, _movie} =
               MovieLifecycle.track(movie, %{
                 download_progress: 1.0,
                 download_speed: 0,
                 download_eta: 0
               })

      put_env(:import_roots, [])
      start_supervised!({Poller, interval: 60_000})

      stub(Cinder.Download.ClientMock, :status, fn "dl-roots" ->
        {:ok, %{state: :completed, content_path: "/downloads/Better.1080p.mkv"}}
      end)

      log = capture_log(fn -> assert :ok = Poller.poll() end)

      assert %Movie{
               status: :upgrading,
               import_attempts: 9,
               download_id: "dl-roots",
               download_protocol: :torrent,
               release_title: "Better.1080p-GRP",
               file_path: "/lib/M (2020)/M (2020).mkv",
               download_progress: 1.0,
               download_speed: 0,
               download_eta: 0
             } = Repo.get!(Movie, movie.id)

      assert log =~ "download import roots not configured"
      refute log =~ "/downloads/Better.1080p.mkv"
    end

    test "a nearly full movies library root holds the import before staging" do
      movie =
        movie_fixture(%{
          tmdb_id: 78,
          title: "M",
          status: :downloaded,
          content_path: "/downloads/M.mkv",
          download_id: "hash-hold"
        })

      set_disk_stub!({:ok, %{free_bytes: 500_000_000, total_bytes: 100_000_000_000}})

      # Staging's first filesystem call reports here: a held import must never reach it.
      test_pid = self()

      stub(Cinder.Library.FilesystemMock, :dir?, fn path ->
        send(test_pid, {:staging, path})
        false
      end)

      start_supervised!({Poller, interval: 60_000})

      log = capture_log(fn -> assert :ok = Poller.poll() end)

      assert %Movie{status: :downloaded, import_attempts: attempts} = Repo.get!(Movie, movie.id)
      assert (attempts || 0) == 0
      assert log =~ "nearly full"
      refute_received {:staging, _path}
    end
  end

  describe "the search pass:" do
    test "auto-wires a :requested movie through to :available with no manual Download.start call" do
      {:ok, movie} =
        Catalog.add_movie(%{tmdb_id: 900, title: "Inception", imdb_id: "tt1375666"})

      assert movie.status == :requested

      stub(Cinder.Acquisition.IndexerMock, :search, fn "tt1375666" ->
        {:ok,
         [
           %{
             title: "Inception.2010.1080p.BluRay.x264-GRP",
             size: 8_000_000_000,
             download_url: "magnet:?x",
             seeders: 10
           }
         ]}
      end)

      stub(Cinder.Download.ClientMock, :add, fn _release, _opts -> {:ok, "hash-900"} end)

      stub(Cinder.Download.ClientMock, :status, fn "hash-900" ->
        {:ok, %{state: :completed, content_path: "/downloads/Inception.mkv"}}
      end)

      stub_import_ok()

      start_supervised!({Poller, interval: 60_000, search_retry_after: 0})

      # search runs last in a tick: poll 1 → :downloading, poll 2 → :downloaded → :available
      assert :ok = Poller.poll()
      assert :ok = Poller.poll()
      assert %Movie{status: :available} = Repo.get!(Movie, movie.id)
    end

    test "invalid Anime movie preferences hold without searching or consuming attempts" do
      put_config(:anime_preferences, embedded_subtitle_mode: :require)

      movie =
        movie_fixture(%{
          title: "Invalid Anime",
          year: 2020,
          imdb_id: "tt-anime-invalid",
          media_profile: :anime
        })

      searches = start_supervised!({Agent, fn -> 0 end})

      stub(Cinder.Acquisition.IndexerMock, :search, fn _imdb_id ->
        Agent.update(searches, &(&1 + 1))
        {:ok, []}
      end)

      stub(Cinder.Acquisition.IndexerMock, :search_movie_query, fn _query, _opts ->
        Agent.update(searches, &(&1 + 1))
        {:ok, []}
      end)

      start_supervised!({Poller, interval: 60_000, search_retry_after: 0})
      assert :ok = Poller.poll()

      assert %Movie{status: :searching, search_attempts: 0} = Repo.get!(Movie, movie.id)
      assert Agent.get(searches, & &1) == 0

      # The hold is DB-visible (issue #107) — the badge reads "Needs preferences", not "Searching".
      assert Repo.get!(Movie, movie.id).anime_hold_reason == "subtitle_language_required"

      # Preferences become satisfiable → the next sweep clears the hold and searches normally.
      put_config(:anime_preferences, embedded_subtitle_mode: :prefer)
      assert :ok = Poller.poll()

      assert Repo.get!(Movie, movie.id).anime_hold_reason == nil
      assert Agent.get(searches, & &1) > 0
    end

    test "search skips the grab (no park, no attempt bump) when the download root can't hold it" do
      {:ok, movie} = Catalog.add_movie(%{tmdb_id: 77, title: "Big", imdb_id: "tt7777777"})

      set_disk_stub!({:ok, %{free_bytes: 1_000_000_000, total_bytes: 100_000_000_000}})

      stub(Cinder.Acquisition.IndexerMock, :search, fn "tt7777777" ->
        {:ok,
         [
           %{
             title: "Big.2020.1080p.BluRay.x264-GRP",
             size: 8_000_000_000,
             download_url: "magnet:?x",
             seeders: 10
           }
         ]}
      end)

      # ClientMock.add is intentionally NOT stubbed — a disk-blocked grab must never reach the client
      # (set_mox_global would raise on an unexpected call).
      start_supervised!({Poller, interval: 60_000})

      log = capture_log(fn -> assert :ok = Poller.poll() end)

      movie = Repo.get!(Movie, movie.id)
      assert movie.status in [:requested, :searching]
      assert (movie.search_attempts || 0) == 0
      assert log =~ "insufficient free disk space"
      assert Repo.aggregate(Intent, :count) == 0
    end

    # A re-queued movie whose old download's client removal failed: `Download.start/1` retries
    # that cleanup before any new search, and while the retry backs off the search waits. A wait
    # is not a failed search. The intent is a cleanup, not a counted submission, so the
    # lifecycle's own already-counted check stays out of it; one strike short of the search
    # budget, a strike would park the movie.
    test "a movie whose previous download's cleanup is backing off takes no strike" do
      # An IMDb id, so a search that ran anyway would reach the indexer spy below.
      movie = movie_fixture(%{imdb_id: "tt0000903"})
      {:ok, movie} = seed_movie_state(movie, %{search_attempts: 9})

      Repo.insert!(%Intent{
        operation_key: Ecto.UUID.generate(),
        kind: :movie,
        target_id: movie.id,
        protocol: :torrent,
        release: %{"title" => "Old.Release-GRP"},
        status: :cleanup_pending,
        remote_id: "hash-old",
        next_attempt_at: DateTime.add(DateTime.utc_now(:second), 300, :second)
      })

      # Neither the removal nor a new search may run while the cleanup backs off.
      test_pid = self()

      stub(Cinder.Download.ClientMock, :remove, fn id, _opts ->
        send(test_pid, {:removed, id})
        :ok
      end)

      stub(Cinder.Acquisition.IndexerMock, :search, fn imdb_id ->
        send(test_pid, {:searched, imdb_id})
        {:ok, []}
      end)

      start_supervised!({Poller, interval: 60_000, search_retry_after: 0})
      assert :ok = Poller.poll()

      assert %Movie{status: :requested, search_attempts: 9} = Repo.get!(Movie, movie.id)
      assert %Intent{status: :cleanup_pending} = Repo.get_by!(Intent, target_id: movie.id)
      refute_received {:removed, _id}
      refute_received {:searched, _imdb_id}
    end

    # A search that fails before it starts (TMDB down while resolving the IMDb id) leaves the
    # movie :requested, and the write-back still counts it.
    test "a search that fails before it starts takes a strike and stays :requested" do
      {:ok, movie} = Catalog.add_movie(%{tmdb_id: 905, title: "N"})
      stub(Cinder.Catalog.TMDBMock, :get_movie, fn 905 -> {:error, {:tmdb_status, 503}} end)
      start_supervised!({Poller, interval: 60_000, search_retry_after: 0})

      assert :ok = Poller.poll()
      assert %Movie{status: :requested, search_attempts: 1} = Repo.get!(Movie, movie.id)
    end

    test "backoff: a just-failed movie is not re-attempted until retry_after elapses" do
      {:ok, movie} = Catalog.add_movie(%{tmdb_id: 902, title: "M", imdb_id: "tt2"})
      stub(Cinder.Acquisition.IndexerMock, :search, fn "tt2" -> {:error, :prowlarr_down} end)

      start_supervised!({Poller, interval: 60_000, search_retry_after: 60})

      # First poll: fresh (attempts 0) → attempted → search_attempts becomes 1. The write-back
      # reads the row fresh: the search moved it to :searching mid-unit.
      assert :ok = Poller.poll()
      assert Repo.get!(Movie, movie.id).search_attempts == 1

      # Second poll immediately: not due (updated_at is ~now) → not attempted.
      assert :ok = Poller.poll()
      assert Repo.get!(Movie, movie.id).search_attempts == 1

      # Back-date updated_at past the window → due again → attempted.
      past = DateTime.utc_now() |> DateTime.add(-61, :second) |> DateTime.truncate(:second)
      Repo.update_all(Movie, set: [updated_at: past])
      assert :ok = Poller.poll()
      assert Repo.get!(Movie, movie.id).search_attempts == 2
    end
  end

  describe "recovery:" do
    test "the poller recovers from a crash and still advances work (OTP payoff)" do
      movie = downloading_movie(4, "hash-4")
      pid = start_supervised!({Poller, interval: 60_000})

      stub(Cinder.Download.ClientMock, :status, fn "hash-4" ->
        {:ok, %{state: :completed, content_path: "/downloads/M.mkv"}}
      end)

      stub_import_ok()

      Process.exit(pid, :kill)
      new_pid = await_restart(Poller, pid)
      assert new_pid != pid

      assert :ok = Poller.poll(new_pid)
      assert %Movie{status: :available} = Repo.get!(Movie, movie.id)
    end

    test "recovers a remotely accepted movie after process death without submitting twice" do
      {:ok, movie} =
        Catalog.add_movie(%{tmdb_id: 401, title: "Crash Window", imdb_id: "tt0000401"})

      stub(Cinder.Acquisition.IndexerMock, :search, fn "tt0000401" ->
        {:ok,
         [
           %{
             title: "Crash.Window.1080p.WEB-GRP",
             size: 2_000_000_000,
             download_url: "magnet:?xt=urn:btih:crash",
             seeders: 1
           }
         ]}
      end)

      accepted = start_supervised!({Agent, fn -> %{adds: 0, jobs: %{}} end})

      stub(Cinder.Download.ClientMock, :add, fn _release, operation_key: key ->
        Agent.update(accepted, fn state ->
          %{state | adds: state.adds + 1, jobs: Map.put(state.jobs, key, "hash-crash")}
        end)

        Process.exit(self(), :kill)
      end)

      stub(Cinder.Download.ClientMock, :find_by_operation_key, fn key ->
        case Agent.get(accepted, &Map.get(&1.jobs, key)) do
          nil -> :not_found
          id -> {:ok, id}
        end
      end)

      stub(Cinder.Download.ClientMock, :status, fn "hash-crash" ->
        {:ok, %{state: :downloading, progress: 0.0}}
      end)

      pid = start_supervised!({Poller, interval: 60_000, search_retry_after: 0})
      catch_exit(Poller.poll(pid))

      new_pid = await_restart(Poller, pid)
      assert :ok = Poller.poll(new_pid)

      assert %{adds: 1} = Agent.get(accepted, & &1)

      assert %Movie{status: :downloading, download_id: "hash-crash"} =
               Repo.get!(Movie, movie.id)
    end

    # #415: the lifecycle fences the post-import client removal, so a removal that fails survives
    # as a cleanup intent. Each tick reconciles the movie intents first, which drains it.
    test "a later tick drains the cleanup intent a failed post-import removal left" do
      put_env(:move_on_import, true)

      movie = downloading_movie(90, "nzo-90", download_protocol: :usenet)
      start_supervised!({Poller, interval: 60_000})

      stub(Cinder.Download.SabnzbdClientMock, :status, fn "nzo-90" ->
        {:ok, %{state: :completed, content_path: "/downloads/M90.mkv"}}
      end)

      stub_import_ok()

      # The immediate best-effort removal fails transiently (client restarting, an API timeout).
      expect(Cinder.Download.SabnzbdClientMock, :remove, fn "nzo-90", _opts ->
        {:error, :timeout}
      end)

      assert :ok = Poller.poll()

      # The movie imports and goes available, and its download_id survives untouched (issue
      # #415's secondary claim — see Cleaner's claimed_ids/2).
      reloaded = Repo.get!(Movie, movie.id)
      assert reloaded.status == :available
      assert reloaded.download_id == "nzo-90"

      intent = Repo.get_by!(Intent, kind: :movie, target_id: movie.id)
      assert intent.status == :cleanup_pending

      # Simulate the bounded retry becoming due: a failed attempt backs off rather than retrying
      # on the very next tick.
      intent |> Ecto.Changeset.change(next_attempt_at: nil) |> Repo.update!()

      test_pid = self()

      expect(Cinder.Download.SabnzbdClientMock, :remove, fn "nzo-90", _opts ->
        send(test_pid, :removed_again)
        :ok
      end)

      assert :ok = Poller.poll()

      assert_received :removed_again
      refute Repo.get(Intent, intent.id)
      # Draining the cleanup record is not itself a movie-state change.
      assert Repo.get!(Movie, movie.id).status == :available
    end
  end
end
