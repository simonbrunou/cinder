defmodule Cinder.Catalog.MovieLifecycleTest do
  # Not async: `[:cinder, :transition]` handlers are global, so "emits exactly once" holds only
  # while no other test module emits at the same time (sync modules run one at a time).
  use Cinder.DataCase, async: false

  # The failure verbs log their outcome the way operators read it; keep the test output clean.
  @moduletag :capture_log

  import Cinder.CatalogFixtures

  alias Cinder.Audit.AdminAudit
  alias Cinder.Catalog
  alias Cinder.Catalog.{Attention, BlockedRelease, Movie, MovieLifecycle}
  alias Cinder.Library.StagedImport

  setup do
    :ok = Catalog.subscribe()
  end

  # Runs `fun` and returns `{result, transition_events, movie_broadcasts}` for `movie_id`. Earlier
  # broadcasts for `movie_id` (its fixture's seeding) are dropped first.
  defp published(movie_id, fun) do
    drain_broadcasts(movie_id)
    {result, events} = Cinder.TelemetryHelpers.capture([:cinder, :transition], fun)
    {result, events, drain_broadcasts(movie_id)}
  end

  defp drain_broadcasts(movie_id) do
    receive do
      {:movie_updated, %Movie{id: ^movie_id} = movie} -> [movie | drain_broadcasts(movie_id)]
    after
      0 -> []
    end
  end

  defp admin, do: Cinder.AccountsFixtures.admin_fixture()

  defp hold_fixture(origin, extra \\ %{}) do
    status = if origin == :download, do: :downloaded, else: :upgrading

    movie =
      movie_fixture(
        Map.merge(
          %{status: status, release_title: "Held.Release-GRP", file_path: "/lib/M.mkv"},
          extra
        )
      )

    {:ok, held} =
      seed_movie_state(movie, %{
        status: :import_failed,
        import_attempts: 10,
        verification_hold_origin: origin
      })

    held
  end

  describe "transitions/0" do
    test "lists every edge production takes, and nothing more" do
      assert MovieLifecycle.transitions() == %{
               requested: [:searching, :downloading, :search_failed, :cancelled, :available],
               searching: [:downloading, :no_match, :search_failed, :cancelled],
               downloading: [:downloaded, :import_failed, :requested, :cancelled],
               downloaded: [:available, :import_failed, :requested, :cancelled],
               available: [:upgrading],
               upgrading: [:available, :import_failed],
               no_match: [:requested, :downloading],
               search_failed: [:requested, :downloading],
               import_failed: [
                 :requested,
                 :downloading,
                 :downloaded,
                 :upgrading,
                 :cancelled,
                 :available
               ],
               cancelled: []
             }
    end

    test "classifies every status of the Movie enum" do
      assert Enum.sort(Map.keys(MovieLifecycle.transitions())) ==
               Enum.sort(Ecto.Enum.values(Movie, :status))
    end

    test ":requested is no longer a source for every status" do
      refute MovieLifecycle.legal?(:requested, :upgrading)
      refute MovieLifecycle.legal?(:requested, :downloaded)
      assert MovieLifecycle.legal?(:requested, :requested)
    end
  end

  describe "retry/1" do
    test "re-queues a parked movie with its stale download cleared, and publishes once" do
      movie =
        movie_fixture(%{
          status: :import_failed,
          release_title: "Bad.Release-GRP",
          file_path: "/downloads/bad.mkv",
          content_path: "/downloads/bad"
        })

      {:ok, movie} = seed_movie_state(movie, %{search_attempts: 4, import_attempts: 10})

      {result, events, broadcasts} = published(movie.id, fn -> MovieLifecycle.retry(movie) end)

      assert {:ok,
              %Movie{
                status: :requested,
                search_attempts: 0,
                import_attempts: 0,
                release_title: nil,
                file_path: nil,
                content_path: nil
              }} = result

      assert [{%{count: 1}, %{kind: :movie, to: :requested}}] = events
      assert [%Movie{status: :requested}] = broadcasts
    end

    test "gives a stalled release one fresh chance but keeps a deterministic block" do
      movie = movie_fixture(%{status: :no_match})
      Catalog.block_release(%{movie | release_title: "Stalled-GRP"}, :stalled)
      Catalog.block_release(%{movie | release_title: "WrongLang-GRP"}, :wrong_audio_language)

      assert {:ok, _} = MovieLifecycle.retry(movie)
      assert Catalog.blocked_release_titles(movie) == ["WrongLang-GRP"]
    end

    test "releases a verification hold back to the status it was held from" do
      held = hold_fixture(:download, %{content_path: "/downloads/held"})

      assert {:ok,
              %Movie{
                status: :downloaded,
                import_attempts: 0,
                verification_hold_origin: nil,
                release_title: "Held.Release-GRP",
                content_path: "/downloads/held"
              }} = MovieLifecycle.retry(held)

      assert {:ok, %Movie{status: :upgrading}} = MovieLifecycle.retry(hold_fixture(:upgrade))
    end

    test "misses, publishing nothing, when the movie moved on since the caller read it" do
      movie = movie_fixture(%{status: :search_failed})
      {:ok, _} = seed_movie_state(movie, %{status: :downloading})

      assert {{:error, :stale_status}, [], []} =
               published(movie.id, fn -> MovieLifecycle.retry(movie) end)

      assert Repo.reload!(movie).status == :downloading
    end

    test "refuses a movie that is not parked" do
      for status <- [:requested, :downloading, :available, :cancelled] do
        assert {:error, :not_retryable} = MovieLifecycle.retry(movie_fixture(%{status: status}))
      end
    end
  end

  describe "cancel/2" do
    test "cancels an active movie, audits it and publishes once" do
      actor = admin()
      movie = movie_fixture(%{status: :downloading})

      {result, events, broadcasts} =
        published(movie.id, fn -> MovieLifecycle.cancel(movie, actor) end)

      assert {:ok, %Movie{status: :cancelled}} = result
      assert [{_, %{to: :cancelled}}] = events
      assert [_] = broadcasts

      assert %AdminAudit{action: "cancel_movie", detail: %{"from" => "downloading"}} =
               Repo.one!(AdminAudit)
    end

    test "cancels a verification hold on a fresh download and drops its download" do
      held = hold_fixture(:download, %{content_path: "/downloads/held"})

      assert {:ok,
              %Movie{
                status: :cancelled,
                verification_hold_origin: nil,
                release_title: nil,
                file_path: nil,
                content_path: nil
              }} = MovieLifecycle.cancel(held, admin())
    end

    test "refuses, writing nothing, a movie that is not cancellable or has moved on" do
      actor = admin()
      available = movie_fixture(%{status: :available})
      assert {:error, :not_cancellable} = MovieLifecycle.cancel(available, actor)

      moved = movie_fixture(%{status: :searching})
      {:ok, _} = seed_movie_state(moved, %{status: :downloading})

      assert {{:error, :not_cancellable}, [], []} =
               published(moved.id, fn -> MovieLifecycle.cancel(moved, actor) end)

      assert Repo.aggregate(AdminAudit, :count) == 0
    end
  end

  describe "abort_upgrade/2" do
    test "reverts an upgrade to :available keeping the live file, audited" do
      movie =
        movie_fixture(%{
          status: :upgrading,
          file_path: "/lib/M.mkv",
          release_title: "Better-GRP",
          imported_resolution: "720p"
        })

      {result, events, _} =
        published(movie.id, fn -> MovieLifecycle.abort_upgrade(movie, admin()) end)

      assert {:ok,
              %Movie{
                status: :available,
                file_path: "/lib/M.mkv",
                imported_resolution: "720p",
                release_title: nil
              }} = result

      assert [{_, %{to: :available}}] = events
      assert %AdminAudit{action: "abort_upgrade"} = Repo.one!(AdminAudit)
    end

    test "releases an upgrade verification hold back to :available" do
      held = hold_fixture(:upgrade)

      assert {:ok, %Movie{status: :available, file_path: "/lib/M.mkv", release_title: nil}} =
               MovieLifecycle.abort_upgrade(held, admin())
    end

    test "misses when the upgrade finished since the caller read it" do
      movie = movie_fixture(%{status: :upgrading, file_path: "/lib/M.mkv"})
      {:ok, _} = seed_movie_state(movie, %{status: :available, file_path: "/lib/New.mkv"})

      assert {{:error, :not_upgrading}, [], []} =
               published(movie.id, fn -> MovieLifecycle.abort_upgrade(movie, admin()) end)

      assert %Movie{status: :available, file_path: "/lib/New.mkv"} = Repo.reload!(movie)
    end

    test "refuses a movie that is not upgrading" do
      assert {:error, :not_upgrading} =
               MovieLifecycle.abort_upgrade(movie_fixture(%{status: :available}), admin())
    end
  end

  describe "start_search/2" do
    test "moves a requested movie to :searching with its IMDb id, published once" do
      movie = movie_fixture()

      {result, events, broadcasts} =
        published(movie.id, fn -> MovieLifecycle.start_search(movie, "tt1375666") end)

      assert {:ok, %Movie{status: :searching, imdb_id: "tt1375666"}} = result
      assert [{_, %{to: :searching}}] = events
      assert [_] = broadcasts
    end

    test "re-affirms :searching, and refuses a movie that is not searchable" do
      searching = movie_fixture(%{status: :searching})
      assert {:ok, %Movie{status: :searching}} = MovieLifecycle.start_search(searching, nil)

      parked = movie_fixture(%{status: :no_match})
      assert {:error, :not_searchable} = MovieLifecycle.start_search(parked, nil)
    end
  end

  describe "no_match/2" do
    test "parks a search with nothing left to grab, silently" do
      Cinder.TestNotifier.subscribe()
      movie = movie_fixture(%{status: :searching})

      assert {:ok, %Movie{status: :no_match, release_policy_snapshot: nil}} =
               MovieLifecycle.no_match(movie, :no_match)

      refute_receive {:notify, _}
    end

    test "tells the household when no release in the wanted language exists" do
      Cinder.TestNotifier.subscribe()
      movie = movie_fixture(%{status: :searching})

      assert {:ok, parked} = MovieLifecycle.no_match(movie, :no_language_match)
      assert_receive {:notify, {:movie_failed, ^parked, :no_language_match}}
    end
  end

  describe "attach/2" do
    @download %{
      download_id: "hash-1",
      download_protocol: :torrent,
      release_title: "Inception.2010.1080p-GRP",
      release_policy_snapshot: nil
    }

    test "starts the download of a requested movie, published once" do
      movie = movie_fixture(%{status: :searching})
      {:ok, movie} = seed_movie_state(movie, %{import_attempts: 3})

      {result, events, _} = published(movie.id, fn -> MovieLifecycle.attach(movie, @download) end)

      assert {:ok,
              %Movie{
                status: :downloading,
                download_id: "hash-1",
                download_protocol: :torrent,
                release_title: "Inception.2010.1080p-GRP",
                import_attempts: 0
              }} = result

      assert [{_, %{to: :downloading}}] = events
    end

    test "gives a parked movie a fresh search budget" do
      movie = movie_fixture(%{status: :import_failed})
      {:ok, movie} = seed_movie_state(movie, %{search_attempts: 7})

      assert {:ok, %Movie{status: :downloading, search_attempts: 0}} =
               MovieLifecycle.attach(movie, @download)
    end

    test "makes an available movie an upgrade, keeping its library file" do
      movie =
        movie_fixture(%{status: :available, file_path: "/lib/M.mkv", content_path: "/old/dl"})

      # The replacement's source only travels on the poller's struct, so no stale path survives.
      assert {:ok,
              %Movie{
                status: :upgrading,
                file_path: "/lib/M.mkv",
                content_path: nil,
                download_id: "hash-1"
              }} = MovieLifecycle.attach(movie, @download)
    end

    test "refuses a movie that already has a download in flight" do
      for status <- [:downloading, :downloaded, :upgrading, :cancelled] do
        assert {:error, :not_attachable} =
                 MovieLifecycle.attach(movie_fixture(%{status: status}), @download)
      end
    end
  end

  describe "record_submission_failure/3" do
    test "counts a strike against the search budget when the claim lands" do
      movie = movie_fixture(%{status: :searching})

      {result, events, broadcasts} =
        published(movie.id, fn ->
          MovieLifecycle.record_submission_failure(movie.id, :client_down, fn -> :ok end)
        end)

      assert result == :ok
      assert [{_, %{to: :searching}}] = events
      assert [%Movie{status: :searching, search_attempts: 1}] = broadcasts
    end

    test "parks the movie at :search_failed on its last strike" do
      Cinder.TestNotifier.subscribe()
      movie = movie_fixture(%{status: :requested})
      {:ok, movie} = seed_movie_state(movie, %{search_attempts: 9})

      {result, parks} =
        Cinder.TelemetryHelpers.capture([:cinder, :park], fn ->
          MovieLifecycle.record_submission_failure(movie.id, :client_down, fn -> :ok end)
        end)

      assert result == :ok
      assert [{_, %{kind: :movie, reason: :client_down}}] = parks
      assert %Movie{status: :search_failed} = Repo.reload!(movie)
      assert_receive {:notify, {:movie_failed, %Movie{status: :search_failed}, :client_down}}
    end

    test "writes nothing when the claim is stale or the movie left the search pass" do
      searching = movie_fixture(%{status: :searching})
      downloading = movie_fixture(%{status: :downloading})

      assert {:ok, [], []} =
               published(searching.id, fn ->
                 MovieLifecycle.record_submission_failure(searching.id, :x, fn -> :stale end)
               end)

      assert {:ok, [], []} =
               published(downloading.id, fn ->
                 MovieLifecycle.record_submission_failure(downloading.id, :x, fn -> :ok end)
               end)

      assert Repo.reload!(searching).search_attempts == 0
    end
  end

  describe "track/2" do
    test "records changed progress once, keeping the high-water mark" do
      movie = movie_fixture(%{status: :downloading})

      {result, events, _} =
        published(movie.id, fn ->
          MovieLifecycle.track(movie, %{download_progress: 0.5, download_speed: 100})
        end)

      assert {:ok, %Movie{download_progress: 0.5, download_speed: 100} = tracked} = result
      assert [{_, %{to: :downloading}}] = events

      assert {:ok, %Movie{download_progress: 0.5, download_speed: 50}} =
               MovieLifecycle.track(tracked, %{download_progress: 0.4, download_speed: 50})
    end

    test "writes and publishes nothing when nothing moved" do
      movie = movie_fixture(%{status: :downloading})
      {:ok, tracked} = MovieLifecycle.track(movie, %{download_progress: 0.5})

      assert {{:ok, ^tracked}, [], []} =
               published(movie.id, fn ->
                 MovieLifecycle.track(tracked, %{download_progress: 0.5})
               end)
    end
  end

  describe "mark_downloaded/2" do
    test "hands a finished download to import with a fresh import budget" do
      movie = movie_fixture(%{status: :downloading})
      {:ok, movie} = seed_movie_state(movie, %{import_attempts: 2})

      assert {:ok, %Movie{status: :downloaded, content_path: "/downloads/M", import_attempts: 0}} =
               MovieLifecycle.mark_downloaded(movie, "/downloads/M")
    end

    test "refuses a movie that is not downloading" do
      for status <- [:downloaded, :upgrading, :requested] do
        assert {:error, :not_downloading} =
                 MovieLifecycle.mark_downloaded(movie_fixture(%{status: status}), "/d")
      end
    end
  end

  # A real library on a temp dir (the local stand-in for the media disk), so a staged import is
  # the real thing, with no filesystem mock.
  defp real_library(%{tmp_dir: tmp}) do
    downloads = Path.join(tmp, "downloads")
    movies = Path.join(tmp, "movies")
    File.mkdir_p!(downloads)
    File.mkdir_p!(movies)

    saved =
      Map.new([:filesystem, :path_policy, :import_roots, :movies_library_path], fn key ->
        {key, Application.get_env(:cinder, key)}
      end)

    Application.put_env(:cinder, :filesystem, Cinder.Library.Filesystem.Disk)
    Application.put_env(:cinder, :path_policy, Cinder.Library.PathPolicy)
    Application.put_env(:cinder, :import_roots, [downloads])
    Application.put_env(:cinder, :movies_library_path, movies)

    on_exit(fn ->
      Enum.each(saved, fn {key, value} -> Application.put_env(:cinder, key, value) end)
    end)

    %{downloads: downloads, movies: movies}
  end

  # A `:downloaded` movie, or an `:upgrading` one with a live library file, and its real stage.
  defp staged(downloads, status \\ :downloaded) do
    source = Path.join(downloads, "M.#{System.unique_integer([:positive])}.1080p.mkv")
    File.write!(source, "video")
    attrs = %{title: "M", year: 2020, status: status, release_title: "M.2020.1080p-GRP"}

    case status do
      :downloaded ->
        movie = movie_fixture(Map.put(attrs, :content_path, source))
        {:ok, stage} = Cinder.Library.stage_movie(movie)
        {movie, stage}

      :upgrading ->
        movie = movie_fixture(attrs)

        live =
          Path.join(Application.fetch_env!(:cinder, :movies_library_path), "live-#{movie.id}.mkv")

        File.write!(live, "original")
        {:ok, movie} = seed_movie_state(movie, %{file_path: live})
        upgrade = %{movie | content_path: source}
        {:ok, stage} = Cinder.Library.stage_movie(upgrade, replace: true)
        {upgrade, stage}
    end
  end

  describe "import_staged/2" do
    @describetag :tmp_dir
    setup :real_library

    test "makes the movie available at the staged file, published once", %{downloads: downloads} do
      Cinder.TestNotifier.subscribe()
      {movie, stage} = staged(downloads)

      {result, events, broadcasts} =
        published(movie.id, fn -> MovieLifecycle.import_staged(movie, stage) end)

      assert {:ok, %Movie{status: :available, content_path: nil} = available} = result
      assert available.file_path == StagedImport.record(stage).file_path
      assert File.exists?(available.file_path)
      assert [{_, %{to: :available}}] = events
      assert [_] = broadcasts
      assert_receive {:notify, {:movie_available, %Movie{status: :available}}}
    end

    test "rolls the staged file back when the movie moved on meanwhile", %{downloads: downloads} do
      {movie, stage} = staged(downloads)
      {:ok, _} = seed_movie_state(movie, %{status: :cancelled})

      assert {:error, :stale_status} = MovieLifecycle.import_staged(movie, stage)
      refute File.exists?(StagedImport.record(stage).file_path)
      assert %Movie{status: :cancelled, file_path: nil} = Repo.reload!(movie)
    end
  end

  describe "reject/2" do
    defp policy_movie(status, extra \\ %{}) do
      movie =
        movie_fixture(
          Map.merge(
            %{status: status, release_title: "Bad.Policy-GRP", file_path: "/downloads/bad.mkv"},
            extra
          )
        )

      {:ok, movie} = seed_movie_state(movie, %{release_policy_snapshot: %{"version" => 1}})
      movie
    end

    test "blocklists a fresh download's release and re-queues the movie" do
      movie = policy_movie(:downloaded, %{content_path: "/downloads/bad"})

      {result, events, _} =
        published(movie.id, fn -> MovieLifecycle.reject(movie, :wrong_audio) end)

      assert {:ok,
              %Movie{
                status: :requested,
                release_title: nil,
                release_policy_snapshot: nil,
                file_path: nil,
                content_path: nil
              }} = result

      assert [{_, %{to: :requested}}] = events

      assert [%BlockedRelease{release_title: "Bad.Policy-GRP", reason: reason}] =
               Repo.all(BlockedRelease)

      assert reason =~ "release_policy_mismatch"
    end

    test "rejects an upgrade's release but keeps the live file and its quality" do
      movie = policy_movie(:upgrading, %{file_path: "/lib/M.mkv", imported_resolution: "720p"})

      assert {:ok,
              %Movie{status: :available, file_path: "/lib/M.mkv", imported_resolution: "720p"}} =
               MovieLifecycle.reject(movie, :wrong_audio)
    end

    test "misses, blocking nothing, when the release changed since the caller read it" do
      movie = policy_movie(:downloaded)
      {:ok, _} = seed_movie_state(movie, %{release_title: "Other.Release-GRP"})

      assert {:error, :stale_release} = MovieLifecycle.reject(movie, :wrong_audio)
      assert Repo.all(BlockedRelease) == []
    end

    test "gives up a release with no title to blocklist instead of staging it every tick" do
      fresh = policy_movie(:downloaded, %{release_title: nil})

      assert {:ok, %Movie{status: :import_failed}} = MovieLifecycle.reject(fresh, :wrong_audio)

      upgrade = policy_movie(:upgrading, %{release_title: nil, file_path: "/lib/M.mkv"})

      assert {:ok, %Movie{status: :available, file_path: "/lib/M.mkv"}} =
               MovieLifecycle.reject(upgrade, :wrong_audio)

      assert Repo.all(BlockedRelease) == []
    end
  end

  describe "record_failure/2 in the search phase" do
    test "parks a permanent search error at once" do
      Cinder.TestNotifier.subscribe()
      movie = movie_fixture(%{status: :searching})

      {result, parks} =
        Cinder.TelemetryHelpers.capture([:cinder, :park], fn ->
          MovieLifecycle.record_failure(movie, :bad_torrent)
        end)

      assert {:ok, %Movie{status: :search_failed}} = result
      assert [{_, %{kind: :movie, reason: :bad_torrent}}] = parks
      assert_receive {:notify, {:movie_failed, %Movie{}, :bad_torrent}}
    end

    test "counts a transient error against the search budget, parking on the last strike" do
      movie = movie_fixture(%{status: :requested})

      assert {:ok, %Movie{status: :requested, search_attempts: 1}} =
               MovieLifecycle.record_failure(movie, :timeout)

      {:ok, movie} = seed_movie_state(movie, %{search_attempts: 9})

      assert {:ok, %Movie{status: :search_failed}} =
               MovieLifecycle.record_failure(movie, :timeout)
    end
  end

  describe "record_failure/2 in the download phase" do
    defp downloading(extra \\ %{}),
      do: movie_fixture(Map.merge(%{status: :downloading, release_title: "Dead-GRP"}, extra))

    test "tolerates two client failures, then blocklists the release and re-queues" do
      Cinder.TestNotifier.subscribe()
      movie = downloading()

      assert {:ok, %Movie{status: :downloading, import_attempts: 1} = movie} =
               MovieLifecycle.record_failure(movie, {:failed, :download_error})

      assert {:ok, %Movie{status: :downloading, import_attempts: 2} = movie} =
               MovieLifecycle.record_failure(movie, {:failed, :download_not_found})

      assert Catalog.blocked_release_titles(movie) == []

      assert {:ok, %Movie{status: :requested, release_title: nil, search_attempts: 1}} =
               MovieLifecycle.record_failure(movie, {:failed, {:download_error, "paused"}})

      assert Catalog.blocked_release_titles(movie) == ["Dead-GRP"]
      assert_receive {:notify, {:movie_failed, %Movie{status: :requested}, :download_error}}
    end

    test "re-queues a job the client no longer knows after its tolerance, blocklisting it" do
      movie = downloading()
      {:ok, movie} = seed_movie_state(movie, %{import_attempts: 2})

      assert {:ok, %Movie{status: :requested, release_title: nil}} =
               MovieLifecycle.record_failure(movie, {:failed, :download_not_found})

      assert [%BlockedRelease{release_title: "Dead-GRP", reason: "download_not_found"}] =
               Repo.all(BlockedRelease)
    end

    test "parks instead of re-queueing when there is no release to blocklist" do
      movie = downloading(%{release_title: nil})
      {:ok, movie} = seed_movie_state(movie, %{import_attempts: 2})

      assert {:ok, %Movie{status: :import_failed, failure_reason: "paused"}} =
               MovieLifecycle.record_failure(movie, {:failed, {:download_error, "paused"}})
    end

    test "re-queues blocked content on first sight" do
      movie = downloading()

      assert {:ok, %Movie{status: :requested}} =
               MovieLifecycle.record_failure(movie, {:blocked_content, "setup.exe"})

      assert [%BlockedRelease{reason: "blocked_content"}] = Repo.all(BlockedRelease)
    end

    test "re-queues a stalled download, blocklisting it as stalled" do
      movie = downloading()

      assert {:ok, %Movie{status: :requested}} = MovieLifecycle.record_failure(movie, :stalled)
      assert [%BlockedRelease{reason: "stalled"}] = Repo.all(BlockedRelease)
    end

    test "parks a download with no client after its budget, blocklisting nothing" do
      movie = downloading()
      {:ok, movie} = seed_movie_state(movie, %{import_attempts: 9})

      assert {:ok, %Movie{status: :import_failed}} =
               MovieLifecycle.record_failure(movie, :no_client)

      assert Repo.all(BlockedRelease) == []
    end

    test "parks a download that never yields a path after its budget, blocklisting it" do
      movie = downloading()
      {:ok, movie} = seed_movie_state(movie, %{import_attempts: 9})

      assert {:ok, %Movie{status: :import_failed}} =
               MovieLifecycle.record_failure(movie, {:failed, :no_content_path})

      assert [%BlockedRelease{reason: "no_content_path"}] = Repo.all(BlockedRelease)
    end
  end

  describe "record_failure/2 in the import phase" do
    defp downloaded(extra \\ %{}),
      do: movie_fixture(Map.merge(%{status: :downloaded, release_title: "Rel-GRP"}, extra))

    test "parks a permanent import failure at once, blocklisting the release, and notifies" do
      Cinder.TestNotifier.subscribe()

      for reason <- [:no_file_path, :no_video_file, :wrong_audio_language] do
        movie = downloaded(%{release_title: "Rel.#{reason}-GRP"})

        {result, parks} =
          Cinder.TelemetryHelpers.capture([:cinder, :park], fn ->
            MovieLifecycle.record_failure(movie, reason)
          end)

        assert {:ok, %Movie{status: :import_failed}} = result
        assert [{%{count: 1}, %{kind: :movie, reason: ^reason}}] = parks
        assert Catalog.blocked_release_titles(movie) == ["Rel.#{reason}-GRP"]
        assert_receive {:notify, {:movie_failed, %Movie{status: :import_failed}, ^reason}}
      end
    end

    test "counts a transient import error, then parks without blocklisting" do
      movie = downloaded()

      assert {:ok, %Movie{status: :downloaded, import_attempts: 1}} =
               MovieLifecycle.record_failure(movie, :eacces)

      {:ok, movie} = seed_movie_state(movie, %{import_attempts: 9})

      assert {:ok, %Movie{status: :import_failed}} = MovieLifecycle.record_failure(movie, :eacces)
      assert Repo.all(BlockedRelease) == []
    end

    test "never holds a download that has not reached import" do
      movie = movie_fixture(%{status: :downloading, release_title: "Rel-GRP"})
      {:ok, movie} = seed_movie_state(movie, %{import_attempts: 9})

      assert {:ok, %Movie{status: :import_failed, verification_hold_origin: nil}} =
               MovieLifecycle.record_failure(movie, {:release_policy_unavailable, :timeout})
    end

    test "holds the release for verification when its policy probe stayed unavailable" do
      Cinder.TestNotifier.subscribe()
      movie = downloaded()
      {:ok, movie} = seed_movie_state(movie, %{import_attempts: 9})
      reason = {:release_policy_unavailable, :timeout}

      assert {:ok,
              %Movie{
                status: :import_failed,
                verification_hold_origin: :download,
                import_attempts: 10,
                release_title: "Rel-GRP"
              }} = MovieLifecycle.record_failure(movie, reason)

      assert_receive {:notify, {:movie_failed, %Movie{}, ^reason}}
    end
  end

  describe "record_failure/2 in an upgrade" do
    defp upgrading(extra \\ %{}) do
      movie_fixture(
        Map.merge(
          %{
            status: :upgrading,
            release_title: "Better-GRP",
            file_path: "/lib/M.mkv",
            imported_resolution: "720p"
          },
          extra
        )
      )
    end

    test "reaps a stalled upgrade back to the live file, blocklisting it as stalled" do
      Cinder.TestNotifier.subscribe()

      assert {:ok, %Movie{status: :available, file_path: "/lib/M.mkv", release_title: nil}} =
               MovieLifecycle.record_failure(upgrading(), :stalled)

      assert [%BlockedRelease{reason: "stalled"}] = Repo.all(BlockedRelease)
      assert_receive {:notify, {:movie_upgrade_failed, %Movie{}, :stalled}}
    end

    test "reverts blocked content at once, blocklisting the replacement" do
      assert {:ok, %Movie{status: :available, imported_resolution: "720p"}} =
               MovieLifecycle.record_failure(upgrading(), {:blocked_content, "setup.exe"})

      assert [%BlockedRelease{reason: "upgrade_failed"}] = Repo.all(BlockedRelease)
    end

    test "reverts on a missing client without blocklisting a good release" do
      assert {:ok, %Movie{status: :available}} =
               MovieLifecycle.record_failure(upgrading(), :no_client)

      assert Repo.all(BlockedRelease) == []
    end

    test "counts a transient failure, then reverts on the last strike" do
      Cinder.TestNotifier.subscribe()

      assert {:ok, %Movie{status: :upgrading, import_attempts: 1}} =
               MovieLifecycle.record_failure(upgrading(), {:failed, :download_error})

      movie = upgrading()
      {:ok, movie} = seed_movie_state(movie, %{import_attempts: 9})

      assert {:ok, %Movie{status: :available, file_path: "/lib/M.mkv"}} =
               MovieLifecycle.record_failure(movie, {:failed, :download_error})

      assert_receive {:notify, {:movie_upgrade_failed, %Movie{}, :download_error}}
    end

    test "holds an upgrade whose policy probe stayed unavailable" do
      movie = upgrading()
      {:ok, movie} = seed_movie_state(movie, %{import_attempts: 9})

      assert {:ok, %Movie{status: :import_failed, verification_hold_origin: :upgrade}} =
               MovieLifecycle.record_failure(movie, {:release_policy_unavailable, :timeout})
    end
  end

  test "record_failure/2 refuses a movie with nothing in flight" do
    for status <- [:available, :cancelled, :no_match, :import_failed] do
      assert {:error, :not_in_flight} =
               MovieLifecycle.record_failure(movie_fixture(%{status: status}), :timeout)
    end
  end

  describe "adopt/3" do
    @path "/library/Dune (2021)/Dune (2021).mkv"

    test "inserts an unknown movie straight at :available and announces its creation" do
      attrs = %{tmdb_id: 438_631, title: "Dune", year: 2021}

      {result, events} =
        Cinder.TelemetryHelpers.capture([:cinder, :transition], fn ->
          MovieLifecycle.adopt(attrs, @path)
        end)

      assert {:ok, %Movie{status: :available, file_path: @path} = movie, :created} = result
      assert events == []
      assert_receive {:movie_created, %Movie{id: id}}
      assert id == movie.id
      refute_receive {:movie_updated, _}
    end

    test "moves an existing requested movie to :available, published once" do
      movie = movie_fixture()

      {result, events, broadcasts} =
        published(movie.id, fn -> MovieLifecycle.adopt(%{tmdb_id: movie.tmdb_id}, @path) end)

      assert {:ok, %Movie{status: :available, file_path: @path}, :existing} = result
      assert [{_, %{to: :available}}] = events
      assert [_] = broadcasts
    end

    test "refuses a requested movie whose download intent could still attach a grab" do
      movie = movie_fixture()

      Repo.insert!(%Cinder.Download.Intent{
        operation_key: Ecto.UUID.generate(),
        kind: :movie,
        target_id: movie.id,
        protocol: :torrent,
        release: %{"title" => "Manual.Grab-GRP"},
        status: :reserved
      })

      assert {:error, :acquisition_in_progress} =
               MovieLifecycle.adopt(%{tmdb_id: movie.tmdb_id}, @path)

      assert %Movie{status: :requested, file_path: nil} = Repo.reload!(movie)
    end

    test "refuses a parked or cancelled movie, which may still own a download intent" do
      for status <- [:no_match, :search_failed, :import_failed, :cancelled] do
        movie = movie_fixture(%{status: status})

        assert {:error, {:illegal_transition, ^status, :available}} =
                 MovieLifecycle.adopt(%{tmdb_id: movie.tmdb_id}, @path)

        assert %Movie{status: ^status, file_path: nil} = Repo.reload!(movie)
      end
    end

    test "assigns the chosen handling, after the revalidation passes" do
      movie = movie_fixture()
      test_pid = self()

      revalidate = fn profile ->
        send(test_pid, {:revalidated, profile})
        :ok
      end

      assert {:ok, %Movie{media_profile: :anime, profile_id: nil}, :existing} =
               MovieLifecycle.adopt(%{tmdb_id: movie.tmdb_id}, @path,
                 profile: {nil, :anime},
                 revalidate: revalidate
               )

      assert_received {:revalidated, nil}
    end

    test "a failed revalidation adopts nothing" do
      movie = movie_fixture()

      assert {:error, :candidate_changed} =
               MovieLifecycle.adopt(%{tmdb_id: movie.tmdb_id}, @path,
                 profile: {nil, :standard},
                 revalidate: fn _profile -> {:error, :candidate_changed} end
               )

      assert %Movie{status: :requested, file_path: nil} = Repo.reload!(movie)
    end

    test "never adopts over a file, an acquisition or a verification hold" do
      with_file = movie_fixture(%{status: :available, file_path: "/library/other.mkv"})
      held = hold_fixture(:download, %{file_path: nil, content_path: "/downloads/held"})

      assert {:error, :already_has_file} =
               MovieLifecycle.adopt(%{tmdb_id: with_file.tmdb_id}, @path)

      for status <- [:searching, :downloading, :downloaded, :upgrading] do
        acquiring = movie_fixture(%{status: status})

        assert {:error, :acquisition_in_progress} =
                 MovieLifecycle.adopt(%{tmdb_id: acquiring.tmdb_id}, @path)

        assert %Movie{status: ^status, file_path: nil} = Repo.reload!(acquiring)
      end

      assert {:error, :acquisition_in_progress} =
               MovieLifecycle.adopt(%{tmdb_id: held.tmdb_id}, @path)

      assert %Movie{status: :import_failed, file_path: nil} = Repo.reload!(held)
    end

    test "refuses an empty path" do
      assert {:error, :invalid_file_path} = MovieLifecycle.adopt(%{tmdb_id: 1, title: "M"}, "")
    end
  end

  describe "every verb" do
    # The cross-product: every edge a verb takes is in the matrix, every matrix edge is taken by
    # some verb, a committed verb publishes exactly once (one `[:cinder, :transition]` and one
    # `{:movie_updated, movie}`), and a refused verb publishes and writes nothing. Rows carry no
    # download, so no client is reached; the staged imports run on a real temp library.
    @describetag :tmp_dir
    setup :real_library

    @statuses [
      :requested,
      :searching,
      :downloading,
      :downloaded,
      :available,
      :upgrading,
      :no_match,
      :search_failed,
      :import_failed,
      :cancelled
    ]

    # Functions that read or classify; everything else the module exports is a verb.
    @readers [
      :transitions,
      :legal?,
      :pipeline_statuses,
      :parked_statuses
    ]

    @next_download %{
      download_id: "next",
      download_protocol: :torrent,
      release_title: "Next-GRP",
      release_policy_snapshot: nil
    }

    # {verb, the plain-row statuses it accepts, call}. Statuses outside the list must be refused.
    defp verbs(actor) do
      [
        {:start_search, [:requested, :searching], &MovieLifecycle.start_search(&1, "tt1")},
        {:no_match, [:searching], &MovieLifecycle.no_match(&1, :no_match)},
        {:attach, [:requested, :searching, :no_match, :search_failed, :import_failed, :available],
         &MovieLifecycle.attach(&1, @next_download)},
        {:record_submission_failure, [:requested, :searching],
         &MovieLifecycle.record_submission_failure(&1.id, :client_down, fn -> :ok end)},
        {:track, [:downloading, :upgrading],
         &MovieLifecycle.track(&1, %{download_progress: 0.5})},
        {:mark_downloaded, [:downloading], &MovieLifecycle.mark_downloaded(&1, "/downloads/M")},
        {:import_staged, [:downloaded, :upgrading],
         &MovieLifecycle.import_staged(&1, StagedImport.new())},
        {:reject, [:downloaded, :upgrading], &MovieLifecycle.reject(&1, :evidence)},
        {:record_failure, [:requested, :searching, :downloading, :downloaded, :upgrading],
         &MovieLifecycle.record_failure(&1, :timeout)},
        {:retry, [:no_match, :search_failed, :import_failed], &MovieLifecycle.retry/1},
        {:cancel, [:requested, :searching, :downloading, :downloaded],
         &MovieLifecycle.cancel(&1, actor)},
        {:abort_upgrade, [:upgrading], &MovieLifecycle.abort_upgrade(&1, actor)},
        {:adopt, [:requested, :available],
         &MovieLifecycle.adopt(%{tmdb_id: &1.tmdb_id}, "/library/M.mkv")}
      ]
    end

    # The outcomes a plain call does not reach: {verb, from, fields seeded first, call}.
    defp outcomes(actor) do
      hold = fn origin -> %{verification_hold_origin: origin, import_attempts: 10} end

      [
        {:record_failure, :requested, %{}, &MovieLifecycle.record_failure(&1, :bad_torrent)},
        {:record_failure, :searching, %{search_attempts: 9},
         &MovieLifecycle.record_failure(&1, :timeout)},
        {:record_submission_failure, :searching, %{search_attempts: 9},
         &MovieLifecycle.record_submission_failure(&1.id, :client_down, fn -> :ok end)},
        {:record_failure, :downloading, %{}, &MovieLifecycle.record_failure(&1, :stalled)},
        {:record_failure, :downloading, %{},
         &MovieLifecycle.record_failure(&1, {:blocked_content, "x.exe"})},
        {:record_failure, :downloading, %{import_attempts: 9},
         &MovieLifecycle.record_failure(&1, :no_client)},
        {:record_failure, :downloaded, %{}, &MovieLifecycle.record_failure(&1, :no_video_file)},
        {:record_failure, :downloaded, %{import_attempts: 9},
         &MovieLifecycle.record_failure(&1, {:release_policy_unavailable, :timeout})},
        {:record_failure, :upgrading, %{}, &MovieLifecycle.record_failure(&1, :stalled)},
        {:record_failure, :upgrading, %{}, &MovieLifecycle.record_failure(&1, :no_client)},
        {:record_failure, :upgrading, %{import_attempts: 9},
         &MovieLifecycle.record_failure(&1, {:release_policy_unavailable, :timeout})},
        {:retry, :import_failed, hold.(:download), &MovieLifecycle.retry/1},
        {:retry, :import_failed, hold.(:upgrade), &MovieLifecycle.retry/1},
        {:cancel, :import_failed, hold.(:download), &MovieLifecycle.cancel(&1, actor)},
        {:abort_upgrade, :import_failed, hold.(:upgrade),
         &MovieLifecycle.abort_upgrade(&1, actor)}
      ]
    end

    defp seed_at(status, fields) do
      movie = movie_fixture(%{status: status, release_title: "Rel-GRP"})
      if fields == %{}, do: movie, else: elem(seed_movie_state(movie, fields), 1)
    end

    # Runs `call` on `movie`, returning `{result, transition events, broadcasts, row after}`.
    defp observe(movie, call) do
      {result, events, broadcasts} = published(movie.id, fn -> call.(movie) end)
      {result, events, broadcasts, Repo.get!(Movie, movie.id)}
    end

    defp committed?({:ok, %Movie{}}), do: true
    defp committed?({:ok, %Movie{}, :existing}), do: true
    defp committed?(:ok), do: true
    defp committed?(_result), do: false

    test "a committed verb takes a matrix edge and publishes exactly once", ctx do
      actor = admin()

      # A staged import needs a real stage, built below.
      plain =
        for {verb, froms, call} <- verbs(actor),
            verb != :import_staged,
            from <- froms,
            do: {verb, from, %{}, call}

      staged_imports =
        for from <- [:downloaded, :upgrading] do
          {movie, stage} = staged(ctx.downloads, from)
          {:import_staged, from, movie, &MovieLifecycle.import_staged(&1, stage)}
        end

      seeded =
        for {verb, from, fields, call} <- plain ++ outcomes(actor),
            do: {verb, from, seed_at(from, fields), call}

      taken =
        for {verb, from, movie, call} <- seeded ++ staged_imports do
          {result, events, broadcasts, after_call} = observe(movie, call)
          to = after_call.status
          label = "#{verb} from #{from} (#{inspect(result)})"

          assert committed?(result), label
          assert MovieLifecycle.legal?(from, to), "#{label} took #{from} -> #{to}"
          assert [{%{count: 1}, %{kind: :movie, to: ^to}}] = events, label
          assert [%Movie{status: ^to}] = broadcasts, label
          {verb, from, to}
        end

      edges = for {_verb, from, to} <- taken, from != to, uniq: true, do: {from, to}

      matrix =
        for {from, tos} <- MovieLifecycle.transitions(), to <- tos, do: {from, to}

      assert Enum.sort(matrix) -- edges == [], "matrix edges no verb takes"

      verbs =
        MovieLifecycle.__info__(:functions)
        |> Enum.map(&elem(&1, 0))
        |> Enum.uniq()
        |> Kernel.--(@readers)

      assert Enum.sort(verbs) == taken |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
    end

    test "each verb accepts exactly the movies that offer its action" do
      actor = admin()

      hold = fn origin ->
        seed_at(:import_failed, %{verification_hold_origin: origin, import_attempts: 10})
      end

      guards = [
        {&Attention.offers?(&1, :retry), &MovieLifecycle.retry/1},
        {&Attention.offers?(&1, :cancel), &MovieLifecycle.cancel(&1, actor)},
        {&Attention.offers?(&1, :cancel_upgrade), &MovieLifecycle.abort_upgrade(&1, actor)}
      ]

      for {guard, verb} <- guards,
          seed <-
            Enum.map(@statuses, &fn -> seed_at(&1, %{}) end) ++
              [fn -> hold.(:download) end, fn -> hold.(:upgrade) end] do
        movie = seed.()

        assert guard.(movie) == committed?(verb.(movie)),
               "#{inspect(guard)} disagrees with its verb on #{movie.status} " <>
                 "(hold #{inspect(movie.verification_hold_origin)})"
      end
    end

    test "a refused verb writes and publishes nothing" do
      actor = admin()

      for {verb, froms, call} <- verbs(actor), status <- @statuses -- froms do
        movie = seed_at(status, %{})
        {result, events, broadcasts, after_call} = observe(movie, call)
        label = "#{verb} from #{status} (#{inspect(result)})"

        assert match?({:error, _}, result) or
                 (verb == :record_submission_failure and result == :ok),
               label

        assert events == [], label
        assert broadcasts == [], label
        assert after_call.status == status and after_call.updated_at == movie.updated_at, label
      end
    end
  end
end
