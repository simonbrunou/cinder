defmodule Cinder.Download.PollerTest do
  use Cinder.DataCase, async: false

  import Mox

  # The poller logs warnings/errors on the import failure paths exercised below;
  # capture them so test output stays pristine (they print on failure).
  @moduletag :capture_log

  alias Cinder.{Catalog, Download}
  alias Cinder.Catalog.Movie
  alias Cinder.Download.Poller
  alias Cinder.Repo

  # The poller runs in its own process (and a fresh pid after a crash), so the
  # mock must be global. Shared Sandbox (async: false) lets those processes use
  # the test-owned DB connection.
  setup :set_mox_global

  defp downloading_movie(tmdb_id, download_id) do
    {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: tmdb_id, title: "M"})
    {:ok, movie} = Catalog.transition(movie, %{status: :downloading, download_id: download_id})
    movie
  end

  defp await_restart(name, old_pid) do
    case GenServer.whereis(name) do
      new_pid when is_pid(new_pid) and new_pid != old_pid ->
        new_pid

      _ ->
        Process.sleep(10)
        await_restart(name, old_pid)
    end
  end

  # Stub a successful single-file import (FS + media server) for the import pass.
  defp stub_successful_import do
    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)
    stub(Cinder.Library.FilesystemMock, :lstat, fn _ -> {:ok, %File.Stat{size: 1, inode: 1}} end)
    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> :ok end)
    stub(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)
  end

  test "a poll drives a completed download through :downloaded to :available" do
    movie = downloading_movie(1, "hash-1")
    Catalog.subscribe()
    start_supervised!({Poller, interval: 60_000})

    stub(Cinder.Download.ClientMock, :status, fn "hash-1" ->
      {:ok, %{state: :completed, content_path: "/downloads/M.mkv"}}
    end)

    stub_successful_import()

    assert :ok = Poller.poll()

    assert %Movie{status: :available} = Repo.get!(Movie, movie.id)
    # Passes through :downloaded (pass 1) then :available (pass 2) in one tick.
    assert_receive {:movie_updated, %Movie{status: :downloaded}}
    assert_receive {:movie_updated, %Movie{status: :available}}
  end

  test "routes status polling to the client matching the movie's download_protocol" do
    {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 20, title: "M"})

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

    stub_successful_import()

    assert :ok = Poller.poll()
    assert %Movie{status: :available} = Repo.get!(Movie, movie.id)
  end

  test "a download_protocol with no configured client is parked at :import_failed (no hang)" do
    # Drop usenet from the client map so a usenet movie's status poll can't resolve
    # a client. async: false + restore keeps the global key sane for other tests.
    original = Application.fetch_env!(:cinder, :download_clients)
    Application.put_env(:cinder, :download_clients, %{torrent: Cinder.Download.ClientMock})
    on_exit(fn -> Application.put_env(:cinder, :download_clients, original) end)

    {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 21, title: "M"})

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

    stub_successful_import()

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

  test "drives a movie through the full state machine: requested -> downloaded" do
    {:ok, movie} =
      Catalog.add_to_watchlist(%{tmdb_id: 3, title: "Inception", imdb_id: "tt1375666"})

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

    stub(Cinder.Download.ClientMock, :add, fn _release -> {:ok, hash} end)

    stub(Cinder.Download.ClientMock, :status, fn ^hash ->
      {:ok, %{state: :completed, content_path: "/downloads/Inception.mkv"}}
    end)

    stub_successful_import()

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

    stub_successful_import()

    Process.exit(pid, :kill)
    new_pid = await_restart(Poller, pid)
    assert new_pid != pid

    assert :ok = Poller.poll(new_pid)
    assert %Movie{status: :available} = Repo.get!(Movie, movie.id)
  end

  defp downloaded_movie(tmdb_id, file_path) do
    {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: tmdb_id, title: "Inception", year: 2010})
    {:ok, movie} = Catalog.transition(movie, %{status: :downloaded, file_path: file_path})
    movie
  end

  # Doubles as the import-pass crash-recovery proof: a movie already stranded at
  # :downloaded (crash after download, before import) is imported on a later poll.
  test "imports a :downloaded movie into the library and marks it :available" do
    movie = downloaded_movie(10, "/downloads/Inception.2010.1080p.mkv")
    Catalog.subscribe()
    start_supervised!({Poller, interval: 60_000})

    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)
    stub(Cinder.Library.FilesystemMock, :lstat, fn _ -> {:ok, %File.Stat{size: 1, inode: 1}} end)
    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> :ok end)
    stub(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)

    assert :ok = Poller.poll()
    assert %Movie{status: :available} = Repo.get!(Movie, movie.id)
    assert_receive {:movie_updated, %Movie{status: :available}}
  end

  test "a best-effort scan failure still advances the movie to :available" do
    movie = downloaded_movie(17, "/downloads/Inception.2010.1080p.mkv")
    start_supervised!({Poller, interval: 60_000})

    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)
    stub(Cinder.Library.FilesystemMock, :lstat, fn _ -> {:ok, %File.Stat{size: 1, inode: 1}} end)
    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> :ok end)
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
    stub(Cinder.Library.FilesystemMock, :lstat, fn _ -> {:ok, %File.Stat{size: 1, inode: 1}} end)
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
      Catalog.add_to_watchlist(%{
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
    stub(Cinder.Library.MediaInfoMock, :audio_languages, fn _ -> {:ok, ["hun"]} end)

    assert :ok = Poller.poll()
    assert %Movie{status: :import_failed} = Repo.get!(Movie, movie.id)
  end

  test "a :downloaded movie with no file_path is parked at :import_failed" do
    {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 13, title: "M"})
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
      Catalog.add_to_watchlist(%{tmdb_id: 900, title: "Inception", imdb_id: "tt1375666"})

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

    stub(Cinder.Download.ClientMock, :add, fn _release -> {:ok, "hash-900"} end)

    stub(Cinder.Download.ClientMock, :status, fn "hash-900" ->
      {:ok, %{state: :completed, content_path: "/downloads/Inception.mkv"}}
    end)

    stub_successful_import()

    start_supervised!({Poller, interval: 60_000, search_retry_after: 0})

    # search runs last in a tick: poll 1 → :downloading, poll 2 → :downloaded → :available
    assert :ok = Poller.poll()
    assert :ok = Poller.poll()
    assert %Movie{status: :available} = Repo.get!(Movie, movie.id)
  end

  test "a persistently transient search error parks :search_failed after max attempts" do
    {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 901, title: "M", imdb_id: "tt1"})
    stub(Cinder.Acquisition.IndexerMock, :search, fn "tt1" -> {:error, :prowlarr_down} end)

    # search_retry_after: 0 → every poll is due
    start_supervised!({Poller, interval: 60_000, search_retry_after: 0})

    Enum.each(1..9, fn _ -> Poller.poll() end)
    refute Repo.get!(Movie, movie.id).status == :search_failed

    assert :ok = Poller.poll()
    assert %Movie{status: :search_failed} = Repo.get!(Movie, movie.id)
  end

  test "backoff: a just-failed movie is not re-attempted until retry_after elapses" do
    {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 902, title: "M", imdb_id: "tt2"})
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
    {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 903, title: "M", imdb_id: "tt3"})

    stub(Cinder.Acquisition.IndexerMock, :search, fn "tt3" ->
      {:ok, [%{title: "M.1080p", size: 8_000_000_000, download_url: "magnet:?x", seeders: 5}]}
    end)

    stub(Cinder.Download.ClientMock, :add, fn _ -> {:error, :unsupported_download_url} end)

    start_supervised!({Poller, interval: 60_000, search_retry_after: 0})

    assert :ok = Poller.poll()
    movie = Repo.get!(Movie, movie.id)
    assert movie.status == :search_failed
    assert movie.search_attempts == 0
  end

  test "genuinely-missing imdb parks :no_match; transient TMDB error retries" do
    {:ok, miss} = Catalog.add_to_watchlist(%{tmdb_id: 904, title: "M"})
    {:ok, flaky} = Catalog.add_to_watchlist(%{tmdb_id: 905, title: "N"})

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
    stub(Cinder.Library.FilesystemMock, :lstat, fn _ -> {:ok, %File.Stat{size: 1, inode: 1}} end)
    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> {:error, :eacces} end)

    # A transient error is retried (stays :downloaded) until the bound is hit.
    Enum.each(1..9, fn _ -> Poller.poll() end)
    assert %Movie{status: :downloaded} = Repo.get!(Movie, movie.id)

    assert :ok = Poller.poll()
    assert %Movie{status: :import_failed} = Repo.get!(Movie, movie.id)
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
    stub_successful_import()

    assert :ok = Poller.poll()
    assert %Movie{status: :available} = Repo.get!(Movie, movie.id)
    assert_receive {:notify, {:movie_available, %Movie{status: :available}}}
  end

  test "a parked movie emits the failed notifier event" do
    Cinder.TestNotifier.subscribe()
    {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 41, title: "M"})
    {:ok, _} = Catalog.transition(movie, %{status: :downloaded})
    start_supervised!({Poller, interval: 60_000})

    assert :ok = Poller.poll()
    assert %Movie{status: :import_failed} = Repo.get!(Movie, movie.id)
    assert_receive {:notify, {:movie_failed, %Movie{status: :import_failed}, :no_file_path}}
  end
end
