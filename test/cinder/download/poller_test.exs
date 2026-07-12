defmodule Cinder.Download.PollerTest do
  use Cinder.DataCase, async: false

  import ExUnit.CaptureLog
  import Mox

  # The poller logs warnings/errors on the import failure paths exercised below;
  # capture them so test output stays pristine (they print on failure).
  @moduletag :capture_log

  alias Cinder.Acquisition.Release
  alias Cinder.{Catalog, Download}
  alias Cinder.Catalog.Movie
  alias Cinder.Download.{Intent, Poller}
  alias Cinder.Library.ImportStage
  alias Cinder.Repo

  import Cinder.CatalogFixtures
  import Cinder.LibraryStubs
  import Cinder.PollerHelpers

  # The poller runs in its own process (and a fresh pid after a crash), so the
  # mock must be global. Shared Sandbox (async: false) lets those processes use
  # the test-owned DB connection.
  setup :set_mox_global

  defp downloading_movie(tmdb_id, download_id) do
    movie_fixture(%{tmdb_id: tmdb_id, title: "M", status: :downloading, download_id: download_id})
  end

  defp upgrading_movie(tmdb_id, download_id) do
    movie_fixture(%{
      tmdb_id: tmdb_id,
      title: "M",
      status: :upgrading,
      download_id: download_id,
      file_path: "/lib/M.mkv"
    })
  end

  defp use_real_library(tmp) do
    downloads = Path.join(tmp, "downloads")
    movies = Path.join(tmp, "movies")
    File.mkdir_p!(downloads)
    File.mkdir_p!(movies)

    saved =
      Map.new([:filesystem, :path_policy, :import_roots, :movies_library_path], fn key ->
        {key, Application.get_env(:cinder, key)}
      end)

    Application.put_env(:cinder, :filesystem, Cinder.Test.BarrierFilesystem)
    Application.put_env(:cinder, :path_policy, Cinder.Library.PathPolicy)
    Application.put_env(:cinder, :import_roots, [downloads])
    Application.put_env(:cinder, :movies_library_path, movies)

    on_exit(fn ->
      Enum.each(saved, fn {key, value} -> Application.put_env(:cinder, key, value) end)
      Application.delete_env(:cinder, :filesystem_barrier)
      Application.delete_env(:cinder, :filesystem_failure)
    end)

    %{downloads: downloads, movies: movies}
  end

  defp import_stat(path, size \\ 1) do
    if String.contains?(path, ".cinder-stage-") or
         not String.starts_with?(path, "/tmp/cinder-test-library/"),
       do: {:ok, %File.Stat{size: size, inode: 1, major_device: 1}},
       else: {:error, :enoent}
  end

  defp real_upgrading_movie(tmp, tmdb_id, download_id) do
    %{downloads: downloads, movies: movies} = use_real_library(tmp)
    source = Path.join(downloads, "M.2020.1080p.mkv")
    dest = Path.join([movies, "M (2020) {tmdb-#{tmdb_id}}", "M (2020) {tmdb-#{tmdb_id}}.mkv"])
    File.mkdir_p!(Path.dirname(dest))
    File.write!(source, "candidate")
    File.write!(dest, "original")

    movie =
      movie_fixture(%{
        tmdb_id: tmdb_id,
        title: "M",
        year: 2020,
        status: :upgrading,
        download_id: download_id,
        download_protocol: :torrent,
        file_path: dest,
        imported_resolution: "720p"
      })

    %{source: source, dest: dest, movie: movie}
  end

  test "a poll drives a completed download through :downloaded to :available" do
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

  test "routes status polling to the client matching the movie's download_protocol" do
    {:ok, movie} = Catalog.add_movie(%{tmdb_id: 20, title: "M"})

    {:ok, movie} =
      Catalog.transition(movie, %{
        status: :downloading,
        download_id: "nzo-20",
        download_protocol: :usenet
      })

    start_supervised!({Poller, interval: 60_000})

    # The usenet client is polled; ClientMock (torrent) has no stub, so a misroute
    # to it would raise.
    stub(Cinder.Download.SabnzbdClientMock, :status, fn "nzo-20" ->
      {:ok, %{state: :completed, content_path: "/downloads/M.mkv"}}
    end)

    stub_import_ok()

    assert :ok = Poller.poll()
    assert %Movie{status: :available} = Repo.get!(Movie, movie.id)
  end

  test "a download_protocol with no configured client is parked at :import_failed (no hang)" do
    # Drop usenet from the client map so a usenet movie's status poll can't resolve
    # a client. async: false + restore keeps the global key sane for other tests.
    original = Application.fetch_env!(:cinder, :download_clients)
    Application.put_env(:cinder, :download_clients, %{torrent: Cinder.Download.ClientMock})
    on_exit(fn -> Application.put_env(:cinder, :download_clients, original) end)

    {:ok, movie} = Catalog.add_movie(%{tmdb_id: 21, title: "M"})

    {:ok, movie} =
      Catalog.transition(movie, %{
        status: :downloading,
        download_id: "nzo-21",
        download_protocol: :usenet
      })

    start_supervised!({Poller, interval: 60_000})

    # Bounded: re-attempts each tick, then parks (does not hang forever).
    Enum.each(1..9, fn _ -> Poller.poll() end)
    assert %Movie{status: :downloading} = Repo.get!(Movie, movie.id)

    assert :ok = Poller.poll()
    assert %Movie{status: :import_failed} = Repo.get!(Movie, movie.id)
  end

  test "import_attempts is reset to 0 on the :downloading -> :downloaded transition" do
    # Download-phase blips (e.g. a transient :error state) increment import_attempts
    # while the movie is still :downloading. The reset on completion stops those
    # from bleeding into — and prematurely exhausting — the import phase's bound.
    movie = downloading_movie(30, "hash-30")
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    start_supervised!({Poller, interval: 60_000})

    stub(Cinder.Download.ClientMock, :status, fn "hash-30" ->
      n = Agent.get_and_update(counter, &{&1, &1 + 1})

      if n < 3,
        do: {:ok, %{state: :error}},
        else: {:ok, %{state: :completed, content_path: "/downloads/M.mkv"}}
    end)

    stub_import_ok()

    # Three download blips bump import_attempts while the movie stays :downloading.
    Enum.each(1..3, fn _ -> Poller.poll() end)
    downloading = Repo.get!(Movie, movie.id)
    assert downloading.status == :downloading
    assert downloading.import_attempts > 0

    # Completion resets the counter, then the import pass advances it the same tick.
    assert :ok = Poller.poll()
    reset = Repo.get!(Movie, movie.id)
    assert reset.status == :available
    assert reset.import_attempts == 0
  end

  test "a non-completed status leaves the movie :downloading" do
    movie = downloading_movie(2, "hash-2")
    start_supervised!({Poller, interval: 60_000})

    stub(Cinder.Download.ClientMock, :status, fn "hash-2" -> {:ok, %{state: :downloading}} end)

    assert :ok = Poller.poll()
    assert %Movie{status: :downloading} = Repo.get!(Movie, movie.id)
  end

  test "publishes a fresh downloading snapshot once" do
    movie = downloading_movie(5, "hash-5")
    movie_id = movie.id
    Catalog.subscribe()
    start_supervised!({Poller, interval: 60_000})

    stub(Cinder.Download.ClientMock, :status, fn "hash-5" ->
      {:ok, %{state: :downloading, progress: 0.42, speed: 1_500_000, eta: 90}}
    end)

    assert :ok = Poller.poll()

    assert %Movie{
             status: :downloading,
             download_progress: 0.42,
             download_speed: 1_500_000,
             download_eta: 90
           } = Repo.get!(Movie, movie.id)

    assert_receive {:movie_updated,
                    %Movie{
                      id: ^movie_id,
                      download_progress: 0.42,
                      download_speed: 1_500_000,
                      download_eta: 90
                    }}

    assert :ok = Poller.poll()
    refute_receive {:movie_updated, _}
  end

  test "publishes a fresh upgrading snapshot" do
    movie = upgrading_movie(6, "hash-6")
    start_supervised!({Poller, interval: 60_000})

    stub(Cinder.Download.ClientMock, :status, fn "hash-6" ->
      {:ok, %{state: :downloading, progress: 0.42, speed: 1_500_000, eta: 90}}
    end)

    assert :ok = Poller.poll()

    assert %Movie{
             status: :upgrading,
             download_progress: 0.42,
             download_speed: 1_500_000,
             download_eta: 90
           } = Repo.get!(Movie, movie.id)
  end

  test "a transient client error clears a downloading snapshot" do
    movie = downloading_movie(7, "hash-7")
    movie_id = movie.id

    assert {:ok, _movie} =
             Catalog.update_movie_download_metrics(movie, %{
               download_progress: 0.42,
               download_speed: 1_500_000,
               download_eta: 90
             })

    Catalog.subscribe()
    start_supervised!({Poller, interval: 60_000})
    stub(Cinder.Download.ClientMock, :status, fn "hash-7" -> {:error, :timeout} end)

    assert :ok = Poller.poll()

    assert %Movie{
             status: :downloading,
             download_progress: nil,
             download_speed: nil,
             download_eta: nil
           } = Repo.get!(Movie, movie.id)

    assert_receive {:movie_updated,
                    %Movie{
                      id: ^movie_id,
                      download_progress: nil,
                      download_speed: nil,
                      download_eta: nil
                    }}
  end

  test "a retryable download error clears a downloading snapshot" do
    movie = downloading_movie(8, "hash-8")

    assert {:ok, _movie} =
             Catalog.update_movie_download_metrics(movie, %{
               download_progress: 0.42,
               download_speed: 1_500_000,
               download_eta: 90
             })

    start_supervised!({Poller, interval: 60_000})
    stub(Cinder.Download.ClientMock, :status, fn "hash-8" -> {:ok, %{state: :error}} end)

    assert :ok = Poller.poll()

    assert %Movie{
             status: :downloading,
             import_attempts: 1,
             download_progress: nil,
             download_speed: nil,
             download_eta: nil
           } = Repo.get!(Movie, movie.id)
  end

  test "a retryable upgrade error clears an upgrading snapshot" do
    movie = upgrading_movie(9, "hash-9")

    assert {:ok, _movie} =
             Catalog.update_movie_download_metrics(movie, %{
               download_progress: 0.42,
               download_speed: 1_500_000,
               download_eta: 90
             })

    start_supervised!({Poller, interval: 60_000})
    stub(Cinder.Download.ClientMock, :status, fn "hash-9" -> {:ok, %{state: :error}} end)

    assert :ok = Poller.poll()

    assert %Movie{
             status: :upgrading,
             import_attempts: 1,
             download_progress: nil,
             download_speed: nil,
             download_eta: nil
           } = Repo.get!(Movie, movie.id)
  end

  test "a completed download clears its snapshot before import" do
    movie = downloading_movie(10, "hash-10")

    assert {:ok, _movie} =
             Catalog.update_movie_download_metrics(movie, %{
               download_progress: 0.42,
               download_speed: 1_500_000,
               download_eta: 90
             })

    Catalog.subscribe()
    start_supervised!({Poller, interval: 60_000})

    stub(Cinder.Download.ClientMock, :status, fn "hash-10" ->
      {:ok, %{state: :completed, content_path: "/downloads/M.mkv"}}
    end)

    stub_import_ok()

    assert :ok = Poller.poll()

    assert_receive {:movie_updated,
                    %Movie{
                      status: :downloaded,
                      download_progress: nil,
                      download_speed: nil,
                      download_eta: nil
                    }}
  end

  test "drives a movie through the full state machine: requested -> downloaded" do
    {:ok, movie} =
      Catalog.add_movie(%{tmdb_id: 3, title: "Inception", imdb_id: "tt1375666"})

    assert movie.status == :requested
    hash = "deadbeef"

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

    stub(Cinder.Download.ClientMock, :add, fn _release, _opts -> {:ok, hash} end)

    stub(Cinder.Download.ClientMock, :status, fn ^hash ->
      {:ok, %{state: :completed, content_path: "/downloads/Inception.mkv"}}
    end)

    stub_import_ok()

    start_supervised!({Poller, interval: 60_000})

    assert {:ok, %Movie{status: :downloading, download_id: ^hash}} = Download.start(movie)
    assert :ok = Poller.poll()
    assert %Movie{status: :available} = Repo.get!(Movie, movie.id)
  end

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

    {:ok, accepted} = Agent.start_link(fn -> %{adds: 0, jobs: %{}} end)

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

  test "an intent backoff does not consume a movie search attempt every poll tick" do
    movie = movie_fixture(%{status: :searching, search_attempts: 2})
    attempts_before = Repo.get!(Movie, movie.id).search_attempts

    assert {:ok, intent} =
             Download.reserve_intent(%{
               kind: :movie,
               target_id: movie.id,
               episode_ids: [],
               protocol: :torrent,
               release: %Release{
                 title: "Backoff.Movie",
                 download_url: "magnet:?x",
                 protocol: :torrent
               }
             })

    intent
    |> Intent.changeset(%{
      attempt_count: 1,
      next_attempt_at: DateTime.utc_now(:second) |> DateTime.add(300, :second)
    })
    |> Repo.update!()

    start_supervised!({Poller, interval: 60_000, search_retry_after: 0})
    assert :ok = Poller.poll()
    assert Repo.get!(Movie, movie.id).search_attempts == attempts_before
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

  # Doubles as the import-pass crash-recovery proof: a movie already stranded at
  # :downloaded (crash after download, before import) is imported on a later poll.
  test "imports a :downloaded movie into the library and marks it :available" do
    movie = downloaded_movie(10, "/downloads/Inception.2010.1080p.mkv")
    Catalog.subscribe()
    start_supervised!({Poller, interval: 60_000})

    test_pid = self()
    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)
    stub(Cinder.Library.FilesystemMock, :lstat, &import_stat/1)
    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)

    stub(Cinder.Library.FilesystemMock, :ln, fn _src, dest ->
      send(test_pid, {:linked, dest})
      :ok
    end)

    stub(Cinder.Library.FilesystemMock, :rename, fn _src, _dest -> :ok end)

    stub(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)

    assert :ok = Poller.poll()
    assert %Movie{status: :available} = Repo.get!(Movie, movie.id)
    assert_receive {:movie_updated, %Movie{status: :available}}

    # After import, file_path must point at the LIBRARY destination (the imported hardlink),
    # not the download source — else delete_files unlinks the download copy and strands the
    # library file on disk.
    assert_receive {:linked, staged_path}
    assert Path.basename(staged_path) =~ ".cinder-stage"
    assert %Movie{file_path: dest} = Repo.get!(Movie, movie.id)
    refute dest == "/downloads/Inception.2010.1080p.mkv"
  end

  @tag :tmp_dir
  test "deleting a movie after file staging rolls the uncommitted destination back", %{
    tmp_dir: tmp
  } do
    %{downloads: downloads} = use_real_library(tmp)
    source = Path.join(downloads, "Inception.2010.1080p.mkv")
    File.write!(source, "candidate")
    movie = downloaded_movie(10_001, source)
    start_supervised!({Poller, interval: 60_000})

    Application.put_env(:cinder, :filesystem_barrier, %{
      owner: self(),
      operation: :rename,
      contains: "Inception (2010) {tmdb-10001}.mkv"
    })

    poll = Task.async(fn -> Poller.poll() end)

    assert_receive {:filesystem_barrier, pid, ref, operation, dest}, 1_000
    assert operation == :rename
    assert File.read!(dest) == "candidate"
    assert {:ok, _deleted} = Catalog.delete_movie(Repo.get!(Movie, movie.id), nil)
    send(pid, {ref, :continue})

    assert :ok = Task.await(poll)
    refute File.exists?(dest)
    assert Repo.get(Movie, movie.id) == nil
  end

  @tag :tmp_dir
  test "a retry removes a candidate left by process death before placement", %{tmp_dir: tmp} do
    %{downloads: downloads, movies: movies} = use_real_library(tmp)
    source = Path.join(downloads, "Inception.2010.1080p.mkv")

    dest =
      Path.join([
        movies,
        "Inception (2010) {tmdb-10004}",
        "Inception (2010) {tmdb-10004}.mkv"
      ])

    operation_key = Ecto.UUID.generate()
    stale = Path.join(Path.dirname(dest), ".cinder-stage-#{operation_key}")
    File.mkdir_p!(Path.dirname(dest))
    File.write!(source, "candidate")
    File.write!(stale, "partial")

    ImportStage.create!(%{
      operation_key: operation_key,
      state: :preparing,
      root: movies,
      dest: dest,
      candidate: stale
    })

    movie = downloaded_movie(10_004, source)
    start_supervised!({Poller, interval: 60_000})
    stub(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

    assert :ok = Poller.poll()
    assert Repo.get!(Movie, movie.id).status == :available
    assert File.read!(dest) == "candidate"
    refute File.exists?(stale)
  end

  @tag :tmp_dir
  test "delayed rollback preserves a user file that replaced the staged destination", %{
    tmp_dir: tmp
  } do
    %{downloads: downloads} = use_real_library(tmp)
    source = Path.join(downloads, "Inception.2010.1080p.mkv")
    File.write!(source, "candidate")
    movie = downloaded_movie(10_005, source)
    start_supervised!({Poller, interval: 60_000})

    Application.put_env(:cinder, :filesystem_barrier, %{
      owner: self(),
      operation: :rename,
      contains: "Inception (2010) {tmdb-10005}.mkv",
      once: true
    })

    poll = Task.async(fn -> Poller.poll() end)
    assert_receive {:filesystem_barrier, pid, ref, :rename, dest}, 1_000
    assert {:ok, _} = Catalog.delete_movie(Repo.get!(Movie, movie.id), nil)
    File.rm!(dest)
    File.write!(dest, "user replacement")
    assert [%ImportStage{state: :preparing, candidate_size: 9}] = Repo.all(ImportStage)
    assert File.stat!(dest).size == 16
    send(pid, {ref, :continue})

    assert :ok = Task.await(poll)
    assert File.read!(dest) == "user replacement"
  end

  test "a best-effort scan failure still advances the movie to :available" do
    movie = downloaded_movie(17, "/downloads/Inception.2010.1080p.mkv")
    start_supervised!({Poller, interval: 60_000})

    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)
    stub(Cinder.Library.FilesystemMock, :lstat, &import_stat/1)
    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> :ok end)
    stub(Cinder.Library.FilesystemMock, :rename, fn _src, _dest -> :ok end)
    # File is hardlinked; only the media-server scan fails. Best-effort: the movie
    # still reaches :available rather than re-stranding at :downloaded.
    stub(Cinder.Library.MediaServerMock, :scan, fn _kind -> {:error, :econnrefused} end)

    assert :ok = Poller.poll()
    assert %Movie{status: :available} = Repo.get!(Movie, movie.id)
  end

  test "a failed import leaves the movie :downloaded for retry" do
    movie = downloaded_movie(11, "/downloads/Inception.2010.1080p.mkv")
    start_supervised!({Poller, interval: 60_000})

    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)
    stub(Cinder.Library.FilesystemMock, :lstat, fn path ->
      if String.contains?(path, ".cinder-stage-"),
        do: {:error, :enoent},
        else: import_stat(path)
    end)

    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> {:error, :eacces} end)

    assert :ok = Poller.poll()
    # :eacces (e.g. a read-only mount) is transient — stays :downloaded for retry.
    assert %Movie{status: :downloaded} = Repo.get!(Movie, movie.id)
  end

  test "a release with no usable video file is parked at :import_failed (no retry loop)" do
    movie = downloaded_movie(12, "/downloads/release-folder")
    start_supervised!({Poller, interval: 60_000})

    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)

    stub(Cinder.Library.FilesystemMock, :find_files, fn _ ->
      {:ok, [{"/downloads/release-folder/readme.nfo", 12}]}
    end)

    assert :ok = Poller.poll()
    assert %Movie{status: :import_failed} = Repo.get!(Movie, movie.id)
  end

  test "a confirmed wrong-language file is parked at :import_failed (MediaInfo safety net)" do
    {:ok, movie} =
      Catalog.add_movie(%{
        tmdb_id: 99,
        title: "Chasse Gardee",
        year: 2024,
        original_language: "fr",
        preferred_language: "original"
      })

    {:ok, movie} =
      Catalog.transition(movie, %{status: :downloaded, file_path: "/downloads/dub.mkv"})

    # Enable the optional probe for this test; the file's only audio track is Hungarian, not French.
    Application.put_env(:cinder, :media_info, Cinder.Library.MediaInfoMock)
    on_exit(fn -> Application.delete_env(:cinder, :media_info) end)

    start_supervised!({Poller, interval: 60_000})
    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)

    stub(Cinder.Library.MediaInfoMock, :probe, fn _ -> {:ok, %{audio: ["hun"], subtitles: []}} end)

    assert :ok = Poller.poll()
    assert %Movie{status: :import_failed} = Repo.get!(Movie, movie.id)
  end

  test "a :downloaded movie with no file_path is parked at :import_failed" do
    {:ok, movie} = Catalog.add_movie(%{tmdb_id: 13, title: "M"})
    {:ok, movie} = Catalog.transition(movie, %{status: :downloaded})
    start_supervised!({Poller, interval: 60_000})

    assert :ok = Poller.poll()
    assert %Movie{status: :import_failed} = Repo.get!(Movie, movie.id)
  end

  test "a completed torrent with no content_path yet stays :downloading (not parked)" do
    movie = downloading_movie(14, "hash-14")
    start_supervised!({Poller, interval: 60_000})

    stub(Cinder.Download.ClientMock, :status, fn "hash-14" ->
      {:ok, %{state: :completed, content_path: nil}}
    end)

    assert :ok = Poller.poll()
    # No final path yet — don't snapshot a nil and prematurely fail; wait a tick.
    assert %Movie{status: :downloading} = Repo.get!(Movie, movie.id)
  end

  test "a completed torrent with an empty content_path also stays :downloading" do
    movie = downloading_movie(15, "hash-15")
    start_supervised!({Poller, interval: 60_000})

    stub(Cinder.Download.ClientMock, :status, fn "hash-15" ->
      {:ok, %{state: :completed, content_path: ""}}
    end)

    assert :ok = Poller.poll()
    assert %Movie{status: :downloading} = Repo.get!(Movie, movie.id)
  end

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

  test "a persistently transient search error parks :search_failed after max attempts" do
    {:ok, movie} = Catalog.add_movie(%{tmdb_id: 901, title: "M", imdb_id: "tt1"})
    stub(Cinder.Acquisition.IndexerMock, :search, fn "tt1" -> {:error, :prowlarr_down} end)

    # search_retry_after: 0 → every poll is due
    start_supervised!({Poller, interval: 60_000, search_retry_after: 0})

    Enum.each(1..9, fn _ -> Poller.poll() end)
    refute Repo.get!(Movie, movie.id).status == :search_failed

    assert :ok = Poller.poll()
    assert %Movie{status: :search_failed} = Repo.get!(Movie, movie.id)
  end

  test "backoff: a just-failed movie is not re-attempted until retry_after elapses" do
    {:ok, movie} = Catalog.add_movie(%{tmdb_id: 902, title: "M", imdb_id: "tt2"})
    stub(Cinder.Acquisition.IndexerMock, :search, fn "tt2" -> {:error, :prowlarr_down} end)

    start_supervised!({Poller, interval: 60_000, search_retry_after: 60})

    # First poll: fresh (attempts 0) → attempted → search_attempts becomes 1.
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

  test "unsupported download URL parks :search_failed immediately (no retry)" do
    {:ok, movie} = Catalog.add_movie(%{tmdb_id: 903, title: "M", imdb_id: "tt3"})

    stub(Cinder.Acquisition.IndexerMock, :search, fn "tt3" ->
      {:ok, [%{title: "M.1080p", size: 8_000_000_000, download_url: "magnet:?x", seeders: 5}]}
    end)

    stub(Cinder.Download.ClientMock, :add, fn _, _opts -> {:error, :unsupported_download_url} end)

    start_supervised!({Poller, interval: 60_000, search_retry_after: 0})

    assert :ok = Poller.poll()
    movie = Repo.get!(Movie, movie.id)
    assert movie.status == :search_failed
    assert movie.search_attempts == 0
  end

  test "a definite add rejection releases the movie for the next search tick" do
    {:ok, movie} = Catalog.add_movie(%{tmdb_id: 906, title: "M", imdb_id: "tt906"})
    {:ok, adds} = Agent.start_link(fn -> 0 end)

    stub(Cinder.Acquisition.IndexerMock, :search, fn "tt906" ->
      {:ok,
       [%{title: "M.1080p.WEB-GRP", size: 8_000_000_000, download_url: "magnet:?x", seeders: 5}]}
    end)

    stub(Cinder.Download.ClientMock, :add, fn _release, _opts ->
      case Agent.get_and_update(adds, &{&1, &1 + 1}) do
        0 -> {:error, :add_rejected}
        _ -> {:ok, "hash-after-rejection"}
      end
    end)

    start_supervised!({Poller, interval: 60_000, search_retry_after: 0})

    assert :ok = Poller.poll()
    assert Repo.get!(Movie, movie.id).status == :searching
    refute Repo.get_by(Intent, kind: :movie, target_id: movie.id)

    assert :ok = Poller.poll()

    assert %Movie{status: :downloading, download_id: "hash-after-rejection"} =
             Repo.get!(Movie, movie.id)
  end

  test "genuinely-missing imdb parks :no_match; transient TMDB error retries" do
    {:ok, miss} = Catalog.add_movie(%{tmdb_id: 904, title: "M"})
    {:ok, flaky} = Catalog.add_movie(%{tmdb_id: 905, title: "N"})

    stub(Cinder.Catalog.TMDBMock, :get_movie, fn
      904 -> {:ok, %{imdb_id: nil}}
      905 -> {:error, {:tmdb_status, 503}}
    end)

    start_supervised!({Poller, interval: 60_000, search_retry_after: 0})

    assert :ok = Poller.poll()
    assert %Movie{status: :no_match} = Repo.get!(Movie, miss.id)
    assert %Movie{status: :requested, search_attempts: 1} = Repo.get!(Movie, flaky.id)
  end

  test "a persistently failing import is parked at :import_failed after max attempts" do
    movie = downloaded_movie(16, "/downloads/Inception.2010.1080p.mkv")
    start_supervised!({Poller, interval: 60_000})

    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)
    stub(Cinder.Library.FilesystemMock, :lstat, fn path ->
      if String.contains?(path, ".cinder-stage-"),
        do: {:error, :enoent},
        else: import_stat(path)
    end)

    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> {:error, :eacces} end)

    # A transient error is retried (stays :downloaded) until the bound is hit.
    Enum.each(1..9, fn _ -> Poller.poll() end)
    assert %Movie{status: :downloaded} = Repo.get!(Movie, movie.id)

    assert :ok = Poller.poll()
    assert %Movie{status: :import_failed} = Repo.get!(Movie, movie.id)
  end

  test "missing download roots hold a downloaded movie without consuming import attempts" do
    movie =
      movie_fixture(%{
        tmdb_id: 401,
        status: :downloaded,
        file_path: "/downloads/held.mkv"
      })

    assert {:ok, movie} =
             Catalog.transition(movie, %{status: :downloaded, import_attempts: 4})

    saved = Application.get_env(:cinder, :import_roots)
    Application.put_env(:cinder, :import_roots, [])
    on_exit(fn -> Application.put_env(:cinder, :import_roots, saved) end)
    start_supervised!({Poller, interval: 60_000})

    log = capture_log(fn -> Enum.each(1..12, fn _ -> Poller.poll() end) end)

    assert %Movie{status: :downloaded, import_attempts: 4} = Repo.get!(Movie, movie.id)
    assert log =~ "download import roots not configured"
    refute log =~ movie.file_path
  end

  test "a completed download that never yields a content_path is parked after max attempts" do
    movie = downloading_movie(17, "hash-17")
    start_supervised!({Poller, interval: 60_000})

    stub(Cinder.Download.ClientMock, :status, fn "hash-17" ->
      {:ok, %{state: :completed, content_path: nil}}
    end)

    Enum.each(1..9, fn _ -> Poller.poll() end)
    assert %Movie{status: :downloading} = Repo.get!(Movie, movie.id)

    assert :ok = Poller.poll()
    assert %Movie{status: :import_failed} = Repo.get!(Movie, movie.id)
  end

  test "a qBittorrent :error state parks :import_failed after max attempts (not before)" do
    movie = downloading_movie(18, "hash-18")
    start_supervised!({Poller, interval: 60_000})

    stub(Cinder.Download.ClientMock, :status, fn "hash-18" ->
      {:ok, %{state: :error}}
    end)

    Enum.each(1..9, fn _ -> Poller.poll() end)
    assert %Movie{status: :downloading} = Repo.get!(Movie, movie.id)

    assert :ok = Poller.poll()
    assert %Movie{status: :import_failed} = Repo.get!(Movie, movie.id)
  end

  test "a torrent not found in qBittorrent parks :import_failed after max attempts (not before)" do
    movie = downloading_movie(19, "hash-19")
    start_supervised!({Poller, interval: 60_000})

    stub(Cinder.Download.ClientMock, :status, fn "hash-19" ->
      {:error, :not_found}
    end)

    Enum.each(1..9, fn _ -> Poller.poll() end)
    assert %Movie{status: :downloading} = Repo.get!(Movie, movie.id)

    assert :ok = Poller.poll()
    assert %Movie{status: :import_failed} = Repo.get!(Movie, movie.id)
  end

  test "a movie reaching :available emits the available notifier event" do
    Cinder.TestNotifier.subscribe()
    movie = downloaded_movie(40, "/downloads/Inception.2010.1080p.mkv")
    start_supervised!({Poller, interval: 60_000})
    stub_import_ok()

    assert :ok = Poller.poll()
    assert %Movie{status: :available} = Repo.get!(Movie, movie.id)
    assert_receive {:notify, {:movie_available, %Movie{status: :available}}}
  end

  test "a parked movie emits the failed notifier event" do
    Cinder.TestNotifier.subscribe()
    {:ok, movie} = Catalog.add_movie(%{tmdb_id: 41, title: "M"})
    {:ok, _} = Catalog.transition(movie, %{status: :downloaded})
    start_supervised!({Poller, interval: 60_000})

    assert :ok = Poller.poll()
    assert %Movie{status: :import_failed} = Repo.get!(Movie, movie.id)
    assert_receive {:notify, {:movie_failed, %Movie{status: :import_failed}, :no_file_path}}
  end

  describe "release blocklist capture" do
    test "a download-side failure that exhausts retries blocks the release; not re-grabbed" do
      movie =
        movie_fixture(%{
          tmdb_id: 50,
          imdb_id: "tt50",
          status: :downloading,
          download_id: "hash-50",
          release_title: "Bad.Release.1080p-GRP"
        })

      start_supervised!({Poller, interval: 60_000})
      stub(Cinder.Download.ClientMock, :status, fn "hash-50" -> {:ok, %{state: :error}} end)

      # Pre-exhaustion polls don't block; the release is only recorded once retries are spent.
      Enum.each(1..9, fn _ -> Poller.poll() end)
      assert Catalog.blocked_release_titles(movie) == []

      assert :ok = Poller.poll()
      assert %Movie{status: :import_failed} = Repo.get!(Movie, movie.id)
      assert Catalog.blocked_release_titles(movie) == ["Bad.Release.1080p-GRP"]

      # Re-queue (retry nils release_title, keeps the blocklist row) and re-search: the only
      # available release is the blocked one, so it parks at :no_match instead of re-grabbing.
      {:ok, requeued} = Catalog.retry_movie(Repo.get!(Movie, movie.id))

      expect(Cinder.Acquisition.IndexerMock, :search, fn _ ->
        {:ok,
         [
           %{
             title: "Bad.Release.1080p-GRP",
             size: 8_000_000_000,
             download_url: "magnet:?xt=urn:btih:bad",
             seeders: 1
           }
         ]}
      end)

      assert {:ok, %Movie{status: :no_match}} = Download.start(requeued)
    end

    test "a permanent import failure (:no_file_path) blocks the release" do
      movie = movie_fixture(%{tmdb_id: 60, status: :downloaded, release_title: "Rel.NoPath-GRP"})
      start_supervised!({Poller, interval: 60_000})

      assert :ok = Poller.poll()
      assert %Movie{status: :import_failed} = Repo.get!(Movie, movie.id)
      assert Catalog.blocked_release_titles(movie) == ["Rel.NoPath-GRP"]
    end

    test "a permanent import failure (:no_video_file) blocks the release" do
      movie =
        movie_fixture(%{
          tmdb_id: 61,
          status: :downloaded,
          file_path: "/downloads/rel-folder",
          release_title: "Rel.NoVideo-GRP"
        })

      start_supervised!({Poller, interval: 60_000})
      stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)

      stub(Cinder.Library.FilesystemMock, :find_files, fn _ ->
        {:ok, [{"/downloads/rel-folder/readme.nfo", 12}]}
      end)

      assert :ok = Poller.poll()
      assert %Movie{status: :import_failed} = Repo.get!(Movie, movie.id)
      assert Catalog.blocked_release_titles(movie) == ["Rel.NoVideo-GRP"]
    end

    test "a confirmed wrong-audio-language park blocks the release" do
      movie =
        movie_fixture(%{
          tmdb_id: 62,
          title: "Chasse Gardee",
          year: 2024,
          original_language: "fr",
          preferred_language: "original",
          status: :downloaded,
          file_path: "/downloads/dub.mkv",
          release_title: "Rel.WrongLang-GRP"
        })

      Application.put_env(:cinder, :media_info, Cinder.Library.MediaInfoMock)
      on_exit(fn -> Application.delete_env(:cinder, :media_info) end)

      start_supervised!({Poller, interval: 60_000})
      stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)

      stub(Cinder.Library.MediaInfoMock, :probe, fn _ ->
        {:ok, %{audio: ["hun"], subtitles: []}}
      end)

      assert :ok = Poller.poll()
      assert %Movie{status: :import_failed} = Repo.get!(Movie, movie.id)
      assert Catalog.blocked_release_titles(movie) == ["Rel.WrongLang-GRP"]
    end
  end

  describe "upgrade advance" do
    test "missing download roots hold a completed upgrade without consuming attempts or metadata" do
      movie =
        movie_fixture(%{
          tmdb_id: 69,
          status: :upgrading,
          download_id: "dl-roots",
          download_protocol: :torrent,
          release_title: "Better.1080p-GRP",
          file_path: "/lib/M (2020)/M (2020).mkv"
        })

      assert {:ok, movie} =
               Catalog.transition(movie, %{status: :upgrading, import_attempts: 4})

      assert {:ok, _movie} =
               Catalog.update_movie_download_metrics(movie, %{
                 download_progress: 1.0,
                 download_speed: 0,
                 download_eta: 0
               })

      saved = Application.get_env(:cinder, :import_roots)
      Application.put_env(:cinder, :import_roots, [])
      on_exit(fn -> Application.put_env(:cinder, :import_roots, saved) end)
      start_supervised!({Poller, interval: 60_000})

      stub(Cinder.Download.ClientMock, :status, fn "dl-roots" ->
        {:ok, %{state: :completed, content_path: "/downloads/Better.1080p.mkv"}}
      end)

      log = capture_log(fn -> Enum.each(1..12, fn _ -> Poller.poll() end) end)

      assert %Movie{
               status: :upgrading,
               import_attempts: 4,
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

      # The canonical library dest already holds the live file (ln -> :eexist); lstat returns the
      # same inode for source+dest, so do_resolve hits the same-inode branch — `replace: true`
      # forces the NEW quality ("1080p") to be recorded there (without the forced replace it would
      # keep the stale "720p", so asserting "1080p" proves the forced replace). The old file at a
      # DIFFERENT path is removed best-effort after the swap.
      test_pid = self()
      stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)

      stub(Cinder.Library.FilesystemMock, :lstat, fn path ->
        if String.contains?(path, [".cinder-rollback-", ".cinder-stage-"]),
          do: {:error, :enoent},
          else: {:ok, %File.Stat{size: 1, inode: 1}}
      end)

      stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
      stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> {:error, :eexist} end)
      stub(Cinder.Library.FilesystemMock, :rm, fn path -> send(test_pid, {:rm, path}) && :ok end)
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

    @tag :tmp_dir
    test "a stale same-path upgrade restores the original bytes", %{tmp_dir: tmp} do
      %{downloads: downloads, movies: movies} = use_real_library(tmp)
      source = Path.join(downloads, "M.2020.1080p.mkv")
      dest = Path.join([movies, "M (2020) {tmdb-10002}", "M (2020) {tmdb-10002}.mkv"])
      File.mkdir_p!(Path.dirname(dest))
      File.write!(source, "candidate")
      File.write!(dest, "original")

      movie =
        movie_fixture(%{
          tmdb_id: 10_002,
          title: "M",
          year: 2020,
          status: :upgrading,
          download_id: "upgrade-10002",
          download_protocol: :torrent,
          file_path: dest,
          imported_resolution: "720p"
        })

      start_supervised!({Poller, interval: 60_000})

      stub(Cinder.Download.ClientMock, :status, fn "upgrade-10002" ->
        {:ok, %{state: :completed, content_path: source}}
      end)

      Application.put_env(:cinder, :filesystem_barrier, %{
        owner: self(),
        operation: :rename,
        contains: Path.basename(dest),
        excludes: ".cinder-rollback",
        once: true
      })

      poll = Task.async(fn -> Poller.poll() end)
      assert_receive {:filesystem_barrier, pid, ref, :rename, ^dest}, 1_000
      assert File.read!(dest) == "candidate"

      assert {:ok, _} =
               Catalog.transition(Repo.get!(Movie, movie.id), %{status: :available},
                 expect: :upgrading
               )

      send(pid, {ref, :continue})

      assert :ok = Task.await(poll)
      assert File.read!(dest) == "original"
      assert Repo.get!(Movie, movie.id).imported_resolution == "720p"
    end

    @tag :tmp_dir
    test "a poller death during same-path staging recovers without rollback debris", %{
      tmp_dir: tmp
    } do
      %{downloads: downloads, movies: movies} = use_real_library(tmp)
      source = Path.join(downloads, "M.2020.1080p.mkv")
      dest = Path.join([movies, "M (2020) {tmdb-10003}", "M (2020) {tmdb-10003}.mkv"])
      File.mkdir_p!(Path.dirname(dest))
      File.write!(source, "candidate")
      File.write!(dest, "original")

      movie =
        movie_fixture(%{
          tmdb_id: 10_003,
          title: "M",
          year: 2020,
          status: :upgrading,
          download_id: "upgrade-10003",
          download_protocol: :torrent,
          file_path: dest,
          imported_resolution: "720p"
        })

      pid = start_supervised!({Poller, interval: 60_000})

      stub(Cinder.Download.ClientMock, :status, fn "upgrade-10003" ->
        {:ok, %{state: :completed, content_path: source}}
      end)

      stub(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

      Application.put_env(:cinder, :filesystem_barrier, %{
        owner: self(),
        operation: :rename,
        contains: Path.basename(dest),
        excludes: ".cinder-rollback",
        once: true
      })

      poll = Task.async(fn -> Poller.poll(pid) end)
      Process.unlink(poll.pid)
      assert_receive {:filesystem_barrier, ^pid, _ref, :rename, ^dest}, 1_000
      assert File.read!(dest) == "candidate"
      Process.exit(pid, :kill)
      catch_exit(Task.await(poll))

      assert Enum.any?(
               File.ls!(Path.dirname(dest)),
               &String.starts_with?(&1, ".cinder-rollback-")
             )

      new_pid = await_restart(Poller, pid)
      assert :ok = Poller.poll(new_pid)
      assert File.read!(dest) == "candidate"
      assert Repo.get!(Movie, movie.id).status == :available

      refute Enum.any?(
               File.ls!(Path.dirname(dest)),
               &String.contains?(&1, ".cinder-")
             )
    end

    @tag :tmp_dir
    test "a poller death after Catalog commit keeps candidate bytes and cleans the backup", %{
      tmp_dir: tmp
    } do
      %{source: source, dest: dest, movie: movie} =
        real_upgrading_movie(tmp, 10_006, "upgrade-10006")

      pid = start_supervised!({Poller, interval: 60_000})

      stub(Cinder.Download.ClientMock, :status, fn "upgrade-10006" ->
        {:ok, %{state: :completed, content_path: source}}
      end)

      Application.put_env(:cinder, :filesystem_barrier, %{
        owner: self(),
        operation: :rm,
        phase: :before,
        contains: ".cinder-rollback",
        once: true
      })

      poll = Task.async(fn -> Poller.poll(pid) end)
      Process.unlink(poll.pid)
      assert_receive {:filesystem_barrier, ^pid, _ref, :rm, backup}, 1_000
      assert Repo.get!(Movie, movie.id).status == :available
      assert File.read!(dest) == "candidate"
      assert File.exists?(backup)

      Process.exit(pid, :kill)
      catch_exit(Task.await(poll))

      new_pid = await_restart(Poller, pid)
      assert :ok = Poller.poll(new_pid)
      assert File.read!(dest) == "candidate"
      refute File.exists?(backup)
      assert :ok = Cinder.Library.reconcile_stages()
    end

    @tag :tmp_dir
    test "a failed rollback restore remains durable and converges on the next poll", %{
      tmp_dir: tmp
    } do
      %{source: source, dest: dest, movie: movie} =
        real_upgrading_movie(tmp, 10_007, "upgrade-10007")

      start_supervised!({Poller, interval: 60_000})

      stub(Cinder.Download.ClientMock, :status, fn "upgrade-10007" ->
        {:ok, %{state: :completed, content_path: source}}
      end)

      Application.put_env(:cinder, :filesystem_barrier, %{
        owner: self(),
        operation: :rename,
        contains: Path.basename(dest),
        excludes: ".cinder-rollback",
        once: true
      })

      Application.put_env(:cinder, :filesystem_failure, %{
        operation: :rename,
        source_contains: ".cinder-rollback",
        reason: :eacces,
        once: true
      })

      poll = Task.async(fn -> Poller.poll() end)
      assert_receive {:filesystem_barrier, pid, ref, :rename, ^dest}, 1_000

      assert {:ok, _} =
               Catalog.transition(Repo.get!(Movie, movie.id), %{status: :available},
                 expect: :upgrading
               )

      send(pid, {ref, :continue})
      assert :ok = Task.await(poll)
      refute File.exists?(dest)
      assert [%ImportStage{last_error: "eacces"}] = Repo.all(ImportStage)

      assert :ok = Poller.poll()
      assert File.read!(dest) == "original"
      assert :ok = Cinder.Library.reconcile_stages()

      refute Enum.any?(
               File.ls!(Path.dirname(dest)),
               &String.contains?(&1, ".cinder-")
             )
    end

    test "a failed upgrade reverts to :available with the old file intact and blocklists the release" do
      movie =
        movie_fixture(%{
          tmdb_id: 71,
          status: :upgrading,
          download_id: "dl-2",
          download_protocol: :torrent,
          release_title: "Bad.1080p-GRP",
          file_path: "/lib/M (2020)/M (2020).mkv"
        })

      start_supervised!({Poller, interval: 60_000})

      expect(Cinder.Download.ClientMock, :status, fn "dl-2" ->
        {:ok, %{state: :completed, content_path: "/dl/Bad"}}
      end)

      # The download yields no usable video file -> :no_video_file (a permanent import error). The
      # upgrade reverts WITHOUT touching the live file and blocklists the release it was told to grab.
      stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)

      stub(Cinder.Library.FilesystemMock, :find_files, fn _ ->
        {:ok, [{"/dl/Bad/readme.nfo", 12}]}
      end)

      assert :ok = Poller.poll()

      reloaded = Repo.get!(Movie, movie.id)
      assert reloaded.status == :available
      assert reloaded.file_path == "/lib/M (2020)/M (2020).mkv"
      assert reloaded.download_id == nil
      assert reloaded.download_protocol == nil
      assert reloaded.release_title == nil
      assert "Bad.1080p-GRP" in Catalog.blocked_release_titles(reloaded)
    end

    test "an upgrade with no configured client reverts to :available without blocklisting" do
      # Drop usenet so the upgrade's status poll can't resolve a client (a config glitch, not a
      # release failure): it must revert the file-safe upgrade but NOT blocklist a good release.
      original = Application.fetch_env!(:cinder, :download_clients)
      Application.put_env(:cinder, :download_clients, %{torrent: Cinder.Download.ClientMock})
      on_exit(fn -> Application.put_env(:cinder, :download_clients, original) end)

      movie =
        movie_fixture(%{
          tmdb_id: 72,
          status: :upgrading,
          download_id: "nzo-72",
          download_protocol: :usenet,
          release_title: "Good.Release-GRP",
          file_path: "/lib/M (2020)/M (2020).mkv"
        })

      start_supervised!({Poller, interval: 60_000})

      assert :ok = Poller.poll()

      reloaded = Repo.get!(Movie, movie.id)
      assert reloaded.status == :available
      assert reloaded.file_path == "/lib/M (2020)/M (2020).mkv"
      assert reloaded.download_id == nil
      assert reloaded.download_protocol == nil
      assert Catalog.blocked_release_titles(reloaded) == []
    end
  end
end
