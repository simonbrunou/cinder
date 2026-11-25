defmodule Cinder.Download.MoveOnImportTest do
  # async: false — drives the global pollers and toggles a global Application env key.
  use Cinder.DataCase, async: false

  import ExUnit.CaptureLog
  import Mox

  # The remove paths log on {:error,_}/raise; capture so output stays pristine.
  @moduletag :capture_log

  alias Cinder.Books
  alias Cinder.Books.BookGrab
  alias Cinder.Catalog
  alias Cinder.Catalog.{BlockedRelease, Episode, Grab, GrabFile, Movie}
  alias Cinder.ConfigCase
  alias Cinder.Download
  alias Cinder.Download.{Intent, IntentEpisode, Poller, SourceRemoval, TvPoller}
  alias Cinder.Library.ImportStage
  alias Cinder.Repo

  import Cinder.CatalogFixtures
  import Cinder.LibraryStubs

  setup :set_mox_global

  # A poll stamps last-run into process-global :persistent_term (PollerSkeleton's `status/0`,
  # read by /healthz); erase it so a recorded run can't bleed into another test/suite.
  setup do
    on_exit(fn ->
      :persistent_term.erase({Poller, :last_run})
      :persistent_term.erase({TvPoller, :last_run})
    end)

    Cinder.PollerHelpers.stub_clean_content()
  end

  # Default off; each test opts in. Restore the key so the overlay can't leak.
  #
  # explicit_import_roots is set here too: Library.delete_download_source/1 now requires an
  # EXPLICITLY configured import root (Settings.explicit_import_roots/0), never an inferred one
  # (issue #119 review) — this file's fixtures use both `/downloads` (movie) and `/dl` (TV) source
  # roots, so both are listed.
  setup do
    saved = Application.get_env(:cinder, :move_on_import)
    saved_roots = Application.get_env(:cinder, :explicit_import_roots)

    Application.put_env(:cinder, :explicit_import_roots, ["/downloads", "/dl"])

    on_exit(fn ->
      case saved do
        nil -> Application.delete_env(:cinder, :move_on_import)
        v -> Application.put_env(:cinder, :move_on_import, v)
      end

      case saved_roots do
        nil -> Application.delete_env(:cinder, :explicit_import_roots)
        v -> Application.put_env(:cinder, :explicit_import_roots, v)
      end
    end)

    :ok
  end

  defp enable, do: Application.put_env(:cinder, :move_on_import, true)

  defp echo_remove(mock) do
    parent = self()

    stub(mock, :remove, fn id, opts ->
      send(parent, {:removed, id, opts})
      :ok
    end)
  end

  # Records each client removal with the cleanup intent its target held at that moment.
  defp record_removals_with_intent(kind, target_id) do
    parent = self()

    stub(Cinder.Download.SabnzbdClientMock, :remove, fn id, _opts ->
      send(parent, {:removed, id, Repo.get_by(Intent, kind: kind, target_id: target_id)})
      :ok
    end)
  end

  defp usenet_book_grab(download_id, content_path \\ nil) do
    {:ok, work} =
      Books.upsert_work(%{
        title: "The Dispossessed",
        identifier: %{
          provider: "openlibrary",
          kind: "work",
          foreign_id: "OL#{System.unique_integer([:positive])}W"
        }
      })

    {:ok, target} = Books.ensure_target(work, :ebook)
    {:ok, grab} = Books.Grabs.create(target.id, download_id, :usenet, "The Dispossessed EPUB")
    grab |> Ecto.Changeset.change(content_path: content_path) |> Repo.update!()
  end

  # A safe default so tests that don't care about the exact rm_rf call don't have to stub it
  # themselves; tests asserting on the argument re-stub it with their own capture.
  defp stub_rm_rf, do: stub(Cinder.Library.FilesystemMock, :rm_rf, fn path -> {:ok, [path]} end)

  defp echo_rm_rf do
    parent = self()

    stub(Cinder.Library.FilesystemMock, :rm_rf, fn path ->
      send(parent, {:rm_rf, path})
      {:ok, [path]}
    end)
  end

  defp stub_single_file_import, do: stub_import_ok()

  defp usenet_movie(tmdb_id, download_id) do
    movie_fixture(%{
      tmdb_id: tmdb_id,
      title: "M",
      status: :downloading,
      download_id: download_id,
      download_protocol: :usenet
    })
  end

  defp drive_to_available(mock, download_id) do
    stub(mock, :status, fn ^download_id ->
      {:ok, %{state: :completed, content_path: "/downloads/M.mkv"}}
    end)

    stub_rm_rf()
    stub_single_file_import()
  end

  defp enable_media_info do
    saved = Application.get_env(:cinder, :media_info)
    Application.put_env(:cinder, :media_info, Cinder.Library.MediaInfoMock)

    on_exit(fn ->
      if saved,
        do: Application.put_env(:cinder, :media_info, saved),
        else: Application.delete_env(:cinder, :media_info)
    end)
  end

  defp release_policy_snapshot(release_title) do
    %{
      "version" => 1,
      "required_audio_languages" => ["ja", "fr"],
      "required_embedded_subtitle_languages" => [],
      "release_group" => "group",
      "release_title" => release_title
    }
  end

  # A :downloaded, usenet-protocol movie carrying a frozen release policy snapshot, so
  # Library.stage_movie/1 runs the post-download MediaInfo verification.
  defp usenet_policy_movie(tmdb_id, download_id, source) do
    movie =
      movie_fixture(%{
        tmdb_id: tmdb_id,
        title: "Anime Movie",
        status: :downloaded,
        download_id: download_id,
        download_protocol: :usenet,
        release_title: "[Group] Anime Movie [1080p]",
        file_path: source
      })

    {:ok, movie} =
      seed_movie_state(movie, %{
        status: :downloaded,
        release_policy_snapshot: release_policy_snapshot(movie.release_title)
      })

    movie
  end

  defp series_tree do
    series = series_fixture(%{tvdb_id: 99, monitor_strategy: :all})
    season = season_fixture(series)
    {series, season}
  end

  defp episode(season, ep_num) do
    episode_fixture(season, %{episode_number: ep_num})
  end

  # A resolved anime-mapping grab, so TvPoller's import path runs the reject-on-mismatch
  # branch (Library.stage_anime_episodes) instead of the standard-TV import. Mirrors
  # tv_poller_test.exs's anime_standard_snapshot/downloaded_policy_grab pattern.
  defp tv_policy_grab(episode, content_path, release_title) do
    grab =
      Repo.insert!(%Grab{
        download_id: "nzo-tv-reject",
        download_protocol: :usenet,
        release_title: release_title,
        content_path: content_path,
        mapping_snapshot: anime_snapshot(episode),
        release_policy_snapshot: release_policy_snapshot(release_title),
        mapping_status: :resolved
      })

    Repo.update_all(from(e in Episode, where: e.id == ^episode.id), set: [grab_id: grab.id])
    grab
  end

  defp anime_snapshot(episode) do
    canonical_value =
      "S01E#{episode.episode_number |> Integer.to_string() |> String.pad_leading(2, "0")}"

    identity = %{
      "source" => "cinder",
      "scheme" => "standard",
      "namespace" => "canonical",
      "canonical_value" => canonical_value
    }

    mapping = %{
      "identity" => identity,
      "precedence" => "manual",
      "episode_ids" => [episode.id],
      "evidence" => nil
    }

    %{
      "version" => 2,
      "parser_context" => %{"title" => "Show", "aliases" => [], "year" => 2008},
      "mappings" => [mapping],
      "reserved_episode_ids" => [episode.id],
      "release" => %{
        "coordinates" => [%{"scheme" => "standard", "values" => [canonical_value]}]
      },
      "selected_resolution" => %{
        "episode_ids" => [episode.id],
        "values" => [
          %{
            "scheme" => "standard",
            "canonical_value" => canonical_value,
            "episode_ids" => [episode.id],
            "precedence" => "manual",
            "mapping_identities" => [identity]
          }
        ]
      }
    }
  end

  describe "SourceRemoval.remove_after_import/3 (the client-remove side)" do
    test "removes a usenet download with delete_files when the toggle is on" do
      enable()
      echo_remove(Cinder.Download.SabnzbdClientMock)
      stub_rm_rf()

      assert :ok = SourceRemoval.remove_after_import(:usenet, "nzo-x", nil)
      assert_receive {:removed, "nzo-x", opts}
      assert opts[:delete_files] == true
    end

    test "is a no-op when the toggle is off" do
      echo_remove(Cinder.Download.SabnzbdClientMock)
      assert :ok = SourceRemoval.remove_after_import(:usenet, "nzo-x", nil)
      refute_receive {:removed, _, _}
    end

    test "is a no-op for torrents, unknown/nil protocol, and blank/nil id (fails safe)" do
      enable()
      echo_remove(Cinder.Download.SabnzbdClientMock)
      echo_remove(Cinder.Download.ClientMock)

      assert :ok = SourceRemoval.remove_after_import(:torrent, "hash-x", nil)
      assert :ok = SourceRemoval.remove_after_import(nil, "x", nil)
      assert :ok = SourceRemoval.remove_after_import(:usenet, nil, "/downloads/x")
      assert :ok = SourceRemoval.remove_after_import(:usenet, "", "/downloads/x")
      refute_receive {:removed, _, _}
    end

    test "a raising client cannot unwind the caller; still returns :ok" do
      enable()
      stub(Cinder.Download.SabnzbdClientMock, :remove, fn _id, _opts -> raise "client down" end)
      assert :ok = SourceRemoval.remove_after_import(:usenet, "nzo-x", nil)
    end

    test "a client {:error,_} is swallowed; returns :ok" do
      enable()
      stub(Cinder.Download.SabnzbdClientMock, :remove, fn _id, _opts -> {:error, :boom} end)
      assert :ok = SourceRemoval.remove_after_import(:usenet, "nzo-x", nil)
    end
  end

  describe "SourceRemoval.remove_after_import/3 (the source-delete side, issue #115)" do
    test "toggle on + usenet -> deletes the whole per-operation/unpack dir via rm_rf regardless of the client" do
      enable()

      # The client has already evicted the job (a la SABnzbd short history_retention_number) — the
      # client-side remove is a no-op, but the source delete must still fire (that's the whole
      # point of #115: cleanup can't depend on the client still tracking the job).
      stub(Cinder.Download.SabnzbdClientMock, :remove, fn _id, _opts -> {:error, :not_found} end)
      echo_rm_rf()

      assert :ok = SourceRemoval.remove_after_import(:usenet, "nzo-x", "/downloads/cinder-abc123")
      assert_receive {:rm_rf, "/downloads/cinder-abc123"}
    end

    # `best_effort_delete_source/1` catches every raise, so a stub that calls `flunk` would stay
    # green when the delete ran: record each call and refute it instead.
    test "toggle off -> does not delete the source" do
      echo_rm_rf()

      assert :ok = SourceRemoval.remove_after_import(:usenet, "nzo-x", "/downloads/cinder-abc123")
      refute_received {:rm_rf, _}
    end

    test "torrent protocol never deletes the source (seeding preserved)" do
      enable()
      echo_rm_rf()

      assert :ok = SourceRemoval.remove_after_import(:torrent, "hash-x", "/downloads/movie.mkv")
      refute_received {:rm_rf, _}
    end

    test "a missing/already-gone dir does not fail (rm_rf finds nothing)" do
      enable()
      echo_remove(Cinder.Download.SabnzbdClientMock)
      stub(Cinder.Library.FilesystemMock, :rm_rf, fn _path -> {:ok, []} end)

      assert :ok = SourceRemoval.remove_after_import(:usenet, "nzo-x", "/downloads/cinder-gone")
    end

    test "a real rm_rf error is swallowed; still returns :ok" do
      enable()
      echo_remove(Cinder.Download.SabnzbdClientMock)
      stub(Cinder.Library.FilesystemMock, :rm_rf, fn path -> {:error, :eacces, path} end)

      assert :ok = SourceRemoval.remove_after_import(:usenet, "nzo-x", "/downloads/cinder-locked")
    end
  end

  # #1447 moved these functions out of `Cinder.Download` and kept their order: a fenced client
  # removal runs only once its cleanup intent is recorded, and an imported book's grab goes before
  # its payload.
  describe "SourceRemoval: the fence comes before the removal" do
    test "a fenced movie removal reaches the client once, after its cleanup intent is recorded" do
      ConfigCase.put_env(:move_on_import, true)
      stub_rm_rf()
      movie = usenet_movie(97, "nzo-fenced")
      record_removals_with_intent(:movie, movie.id)

      assert :ok =
               SourceRemoval.remove_after_import(:usenet, "nzo-fenced", "/downloads/M.mkv",
                 fence: {:movie, movie}
               )

      assert_receive {:removed, "nzo-fenced",
                      %Intent{status: :cleanup_pending, remote_id: "nzo-fenced"}}

      refute_received {:removed, _, _}
    end

    test "a retired book grab reaches the client once, after its cleanup intent is recorded" do
      grab = usenet_book_grab("nzo-book-fenced")
      record_removals_with_intent(:book_target, grab.book_target_id)

      assert :ok = SourceRemoval.retire_book_grab(grab)

      assert_receive {:removed, "nzo-book-fenced",
                      %Intent{status: :cleanup_pending, remote_id: "nzo-book-fenced"}}

      refute_received {:removed, _, _}
    end

    test "an imported book's grab is deleted before its payload" do
      ConfigCase.put_env(:move_on_import, true)
      grab = usenet_book_grab("nzo-book-import", "/downloads/book-import")
      stub(Cinder.Download.SabnzbdClientMock, :remove, fn _id, _opts -> :ok end)
      parent = self()

      stub(Cinder.Library.FilesystemMock, :rm_rf, fn path ->
        send(parent, {:rm_rf, path, Repo.get(BookGrab, grab.id)})
        {:ok, [path]}
      end)

      assert :ok = SourceRemoval.release_imported_book_grab(grab)
      assert_receive {:rm_rf, "/downloads/book-import", nil}
    end
  end

  describe "movie poller" do
    test "usenet + toggle on → removes the download after import; movie :available" do
      enable()
      movie = usenet_movie(1, "nzo-1")
      drive_to_available(Cinder.Download.SabnzbdClientMock, "nzo-1")
      echo_remove(Cinder.Download.SabnzbdClientMock)
      start_supervised!({Poller, interval: 60_000})

      assert :ok = Poller.poll()
      imported = Repo.get!(Movie, movie.id)
      assert imported.status == :available
      # media_info off + single-file download → the capture columns land as [] (not left nil),
      # proving the poller threads q.audio_languages/embedded_subtitles/sidecar_subtitles through.
      assert imported.imported_audio_languages == []
      assert imported.imported_embedded_subtitles == []
      assert imported.imported_sidecar_subtitles == []
      assert_receive {:removed, "nzo-1", [delete_files: true]}
    end

    test "usenet + toggle on → also deletes the download-side source directly (issue #115)" do
      enable()
      movie = usenet_movie(11, "nzo-11")
      drive_to_available(Cinder.Download.SabnzbdClientMock, "nzo-11")
      echo_remove(Cinder.Download.SabnzbdClientMock)
      echo_rm_rf()
      start_supervised!({Poller, interval: 60_000})

      assert :ok = Poller.poll()
      assert %Movie{status: :available} = Repo.get!(Movie, movie.id)
      # movie.file_path (pre-import content_path) is what gets deleted, never the imported dest.
      assert_receive {:rm_rf, "/downloads/M.mkv"}
      refute_receive {:rm_rf, "/tmp/cinder-test-library/M {tmdb-11}/M {tmdb-11}.mkv"}
    end

    # Issue #658: SABnzbd reports a single-file job's `storage` as the FILE inside its
    # "<title>.cinder-<key>" job folder, so deleting the file alone left the folder behind.
    test "a single-file usenet import leaves neither the file nor its .cinder-<key> job folder (issue #658)" do
      enable()
      movie = usenet_movie(13, "nzo-13")
      folder = "/downloads/M.cinder-57431e49-0b5c-4d2e-9f6a-3c1d2e4f5a6b"
      file = folder <> "/M.mkv"
      parent = self()

      stub(Cinder.Download.SabnzbdClientMock, :status, fn "nzo-13" ->
        {:ok, %{state: :completed, content_path: file}}
      end)

      stub_single_file_import()
      echo_remove(Cinder.Download.SabnzbdClientMock)
      echo_rm_rf()

      stub(Cinder.Library.FilesystemMock, :rmdir, fn dir ->
        send(parent, {:rmdir, dir})
        :ok
      end)

      start_supervised!({Poller, interval: 60_000})

      assert :ok = Poller.poll()
      assert %Movie{status: :available} = Repo.get!(Movie, movie.id)
      assert_receive {:rm_rf, ^file}
      assert_receive {:rmdir, ^folder}
    end

    test "an already-gone download-side source doesn't fail the import; movie still :available" do
      enable()
      movie = usenet_movie(12, "nzo-12")
      drive_to_available(Cinder.Download.SabnzbdClientMock, "nzo-12")
      echo_remove(Cinder.Download.SabnzbdClientMock)
      stub(Cinder.Library.FilesystemMock, :rm_rf, fn _path -> {:ok, []} end)
      start_supervised!({Poller, interval: 60_000})

      assert :ok = Poller.poll()
      assert %Movie{status: :available} = Repo.get!(Movie, movie.id)
    end

    test "torrent + toggle on → no remove (seeding preserved)" do
      enable()
      {:ok, movie} = Catalog.add_movie(%{tmdb_id: 2, title: "M"})

      {:ok, movie} =
        seed_movie_state(movie, %{
          status: :downloading,
          download_id: "hash-2",
          download_protocol: :torrent
        })

      drive_to_available(Cinder.Download.ClientMock, "hash-2")
      echo_remove(Cinder.Download.ClientMock)
      start_supervised!({Poller, interval: 60_000})

      assert :ok = Poller.poll()
      assert %Movie{status: :available} = Repo.get!(Movie, movie.id)
      refute_receive {:removed, _, _}
    end

    test "toggle off (default) → no remove; movie still :available" do
      movie = usenet_movie(3, "nzo-3")
      drive_to_available(Cinder.Download.SabnzbdClientMock, "nzo-3")
      echo_remove(Cinder.Download.SabnzbdClientMock)
      start_supervised!({Poller, interval: 60_000})

      assert :ok = Poller.poll()
      assert %Movie{status: :available} = Repo.get!(Movie, movie.id)
      refute_receive {:removed, _, _}
    end

    test "a failed remove leaves the movie :available (no strand, no re-import)" do
      enable()
      movie = usenet_movie(4, "nzo-4")
      drive_to_available(Cinder.Download.SabnzbdClientMock, "nzo-4")
      stub(Cinder.Download.SabnzbdClientMock, :remove, fn _id, _opts -> {:error, :down} end)
      start_supervised!({Poller, interval: 60_000})

      assert :ok = Poller.poll()
      assert %Movie{status: :available} = Repo.get!(Movie, movie.id)
    end

    # #415 review (P1, BLOCKER): the post-commit fence used to look up "the" intent for this
    # target_id with no check that it belonged to the download being fenced. Fencing runs AFTER
    # the import already committed+broadcast — a genuine window for a concurrent re-grab
    # (UpgradeHunter tick, "Find a better match" click) to reserve a brand-new intent for the SAME
    # movie before this call runs. Without the `expect_remote_id` generation guard, that intent
    # would get silently overwritten (flipped to `:cleanup_pending`, its own `remote_id`
    # discarded) instead of left alone.
    test "a concurrent re-grab's intent is never hijacked; the old download still gets a one-shot removal" do
      enable()
      movie = usenet_movie(96, "nzo-old")

      # Simulate the race directly: a concurrent re-grab already reserved a brand-new intent for
      # this same movie target_id (a real `:submitted` shape, matching what `store_remote_id/2`
      # produces) between this tick's import commit and the post-commit fence call below.
      race_intent =
        %Intent{}
        |> Intent.changeset(%{
          operation_key: Ecto.UUID.generate(),
          kind: :movie,
          target_id: movie.id,
          episode_ids: [],
          protocol: :usenet,
          release: %{"title" => "M"},
          status: :submitted,
          remote_id: "nzo-new"
        })
        |> Repo.insert!()

      parent = self()

      stub(Cinder.Download.SabnzbdClientMock, :remove, fn id, opts ->
        send(parent, {:removed, id, opts})
        :ok
      end)

      assert :ok =
               SourceRemoval.remove_after_import(:usenet, "nzo-old", "/downloads/M.mkv",
                 fence: {:movie, movie}
               )

      # The old download still gets removed — one-shot, undurable, but not silently dropped.
      assert_receive {:removed, "nzo-old", [delete_files: true]}

      # The race-winning intent survives byte-identical: never hijacked into :cleanup_pending,
      # its own remote_id intact.
      assert %Intent{status: :submitted, remote_id: "nzo-new"} = Repo.get!(Intent, race_intent.id)

      # No second, corrupted intent was created for the old download either.
      refute Repo.get_by(Intent, kind: :movie, target_id: movie.id, remote_id: "nzo-old")
    end
  end

  describe "upgrade path (issue #115)" do
    test "usenet + toggle on → deletes the NEW download's source, never the old library file" do
      movie =
        movie_fixture(%{
          tmdb_id: 13,
          title: "M",
          status: :upgrading,
          download_id: "nzo-up",
          download_protocol: :usenet,
          release_title: "Better.1080p-GRP",
          file_path: "/lib/M (2020)/M (2020).mkv",
          imported_resolution: "720p"
        })

      enable()
      start_supervised!({Poller, interval: 60_000})

      stub(Cinder.Download.SabnzbdClientMock, :status, fn "nzo-up" ->
        {:ok, %{state: :completed, content_path: "/downloads/cinder-up/Better.1080p.mkv"}}
      end)

      stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)

      stub(Cinder.Library.FilesystemMock, :lstat, fn path ->
        if staging_path?(path),
          do: {:error, :enoent},
          else: {:ok, %File.Stat{type: :regular, size: 1, inode: 1}}
      end)

      stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
      stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> {:error, :eexist} end)
      stub(Cinder.Library.FilesystemMock, :rm, fn _path -> :ok end)
      stub(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)
      echo_remove(Cinder.Download.SabnzbdClientMock)
      echo_rm_rf()

      assert :ok = Poller.poll()
      assert %Movie{status: :available} = Repo.get!(Movie, movie.id)
      assert_receive {:rm_rf, "/downloads/cinder-up/Better.1080p.mkv"}
      refute_receive {:rm_rf, "/lib/M (2020)/M (2020).mkv"}
    end
  end

  describe "movie poller reject path (issue #119 review — reject leaked the download source)" do
    test "a provable policy mismatch is a discard: deletes its download-side source" do
      enable()
      enable_media_info()
      source = "/downloads/cinder-reject/Anime.Movie.mkv"
      movie = usenet_policy_movie(21, "nzo-reject", source)

      expect(Cinder.Library.FilesystemMock, :dir?, fn ^source -> false end)

      expect(Cinder.Library.MediaInfoMock, :probe_policy, fn ^source ->
        {:ok, %{audio: ["ja"], subtitles: [], audio_unknown?: false, subtitle_unknown?: false}}
      end)

      echo_remove(Cinder.Download.SabnzbdClientMock)
      echo_rm_rf()
      start_supervised!({Poller, interval: 60_000})

      assert :ok = Poller.poll()

      assert %Movie{status: :requested, download_id: nil, release_title: nil} =
               Repo.get!(Movie, movie.id)

      assert_receive {:rm_rf, ^source}
      assert_receive {:removed, "nzo-reject", [delete_files: true]}
    end

    test "an unverdictable probe holds for verification: no removal, no cleanup intent" do
      enable()
      enable_media_info()
      source = "/downloads/cinder-hold/Anime.Movie.mkv"
      movie = usenet_policy_movie(22, "nzo-hold", source)
      {:ok, movie} = seed_movie_state(movie, %{status: :downloaded, import_attempts: 9})

      expect(Cinder.Library.FilesystemMock, :dir?, fn ^source -> false end)
      expect(Cinder.Library.MediaInfoMock, :probe_policy, fn ^source -> {:error, :timeout} end)

      # The poller's `isolate/2` and `SourceRemoval`'s best-effort helpers rescue every raise, so
      # a stub that calls `flunk` would stay green when the hold attempted a removal: record each
      # call (the stubs send to this test process from the poller's) and refute it instead.
      record_removals(Cinder.Download.SabnzbdClientMock)
      start_supervised!({Poller, interval: 60_000})
      assert :ok = Poller.poll()

      assert %Movie{status: :import_failed, verification_hold_origin: :download} =
               Repo.get!(Movie, movie.id)

      refute_removals()
      # A fenced intent would have the download removed on a later tick.
      refute Repo.get_by(Intent, kind: :movie, target_id: movie.id, status: :cleanup_pending)
    end
  end

  describe "tv poller" do
    test "usenet grab + toggle on → removes the download exactly once after finish_grab" do
      enable()
      {_series, season} = series_tree()
      e1 = episode(season, 3)
      {:ok, grab} = Catalog.create_grab("nzo-tv", :usenet, [e1.id])

      {:ok, counter} = Agent.start_link(fn -> 0 end)
      parent = self()

      stub(Cinder.Download.SabnzbdClientMock, :status, fn "nzo-tv" ->
        {:ok, %{state: :completed, content_path: "/dl/Show.S01E03.1080p.mkv"}}
      end)

      stub_single_file_import()
      stub_rm_rf()

      stub(Cinder.Download.SabnzbdClientMock, :remove, fn id, opts ->
        Agent.update(counter, &(&1 + 1))
        send(parent, {:removed, id, opts})
        :ok
      end)

      start_supervised!({TvPoller, interval: 60_000})

      assert :ok = TvPoller.poll()
      assert Repo.get(Grab, grab.id) == nil
      assert Repo.get!(Episode, e1.id).file_path =~ "S01E03"
      assert_receive {:removed, "nzo-tv", [delete_files: true]}
      assert Agent.get(counter, & &1) == 1
    end

    test "partial-match pack still removes (don't strand 9 episodes' clutter for 1); deletes the whole per-operation dir" do
      enable()
      {_series, season} = series_tree()
      e1 = episode(season, 1)
      e2 = episode(season, 2)
      {:ok, grab} = Catalog.create_grab("nzo-pack", :usenet, [e1.id, e2.id])
      {:ok, _} = Catalog.mark_grab_downloaded(grab, "/dl/pack")

      stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)

      # Only E01 is present; E02 is unmatched and will re-search.
      stub(Cinder.Library.FilesystemMock, :find_files, fn _ ->
        {:ok, [{"/dl/pack/Show.S01E01.1080p.mkv", 3_000_000_000}]}
      end)

      stub(Cinder.Library.FilesystemMock, :lstat, fn path ->
        if candidate_path?(path) or
             not String.starts_with?(path, "/tmp/cinder-test-tv-library/"),
           do: {:ok, %File.Stat{type: :regular, size: 3_000_000_000, inode: 1, major_device: 1}},
           else: {:error, :enoent}
      end)

      stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
      stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> :ok end)
      stub(Cinder.Library.FilesystemMock, :rename, fn _src, _dest -> :ok end)
      stub(Cinder.Library.FilesystemMock, :rm, fn _path -> :ok end)
      stub(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)
      echo_remove(Cinder.Download.SabnzbdClientMock)
      echo_rm_rf()

      start_supervised!({TvPoller, interval: 60_000})

      assert :ok = TvPoller.poll()
      imported = Repo.get!(Episode, e1.id)
      assert imported.file_path =~ "S01E01"

      # finish_grab's update_all lands the capture columns as [] (not nil), proving it threads them.
      assert imported.imported_audio_languages == []
      assert imported.imported_sidecar_subtitles == []
      assert is_nil(Repo.get!(Episode, e2.id).file_path)
      assert_receive {:removed, "nzo-pack", [delete_files: true]}
      # The whole per-operation/unpack directory is deleted, not just the matched file inside it.
      assert_receive {:rm_rf, "/dl/pack"}
    end

    # #415 review (P2): the cleanup carrier used to reserve EVERY episode the grab ever linked
    # (imported and missing alike), captured via `episode_ids_for_grab/1` before the Catalog
    # call. `commit_grab_imports/close_grab/finish_grab` release the missing ones with
    # `grab_id: nil` for `search_wanted/1` to re-pick up — but the fenced carrier still held
    # E02's `download_intent_episodes` reservation, and `Download.pending_episode_ids/0` excludes
    # anything reserved there, so E02 would silently stop re-searching for as long as the
    # unrelated remote-cleanup intent lived. Uses a FAILING remove (not `echo_remove`) so the
    # fenced intent survives long enough to inspect — an immediately-drained intent proves nothing.
    test "a partial-match pack's cleanup fence reserves only the imported episode, leaving the missing one searchable" do
      enable()
      {_series, season} = series_tree()
      e1 = episode(season, 1)
      e2 = episode(season, 2)
      {:ok, grab} = Catalog.create_grab("nzo-pack-2", :usenet, [e1.id, e2.id])
      {:ok, _} = Catalog.mark_grab_downloaded(grab, "/dl/pack2")

      stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)

      # Only E01 is present; E02 is unmatched and must stay re-searchable.
      stub(Cinder.Library.FilesystemMock, :find_files, fn _ ->
        {:ok, [{"/dl/pack2/Show.S01E01.1080p.mkv", 3_000_000_000}]}
      end)

      stub(Cinder.Library.FilesystemMock, :lstat, fn path ->
        if candidate_path?(path) or
             not String.starts_with?(path, "/tmp/cinder-test-tv-library/"),
           do: {:ok, %File.Stat{type: :regular, size: 3_000_000_000, inode: 1, major_device: 1}},
           else: {:error, :enoent}
      end)

      stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
      stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> :ok end)
      stub(Cinder.Library.FilesystemMock, :rename, fn _src, _dest -> :ok end)
      stub(Cinder.Library.FilesystemMock, :rm, fn _path -> :ok end)
      stub(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)
      stub_rm_rf()
      stub(Cinder.Download.SabnzbdClientMock, :remove, fn _id, _opts -> {:error, :timeout} end)

      start_supervised!({TvPoller, interval: 60_000})
      assert :ok = TvPoller.poll()

      assert Repo.get!(Episode, e1.id).file_path =~ "S01E01"
      assert is_nil(Repo.get!(Episode, e2.id).file_path)

      # The fenced carrier survives (removal failed) and reserves ONLY the imported episode.
      intent = Repo.get_by!(Intent, remote_id: "nzo-pack-2")
      assert intent.status == :cleanup_pending
      assert intent.episode_ids == [e1.id]

      pending = Download.pending_episode_ids()
      assert MapSet.member?(pending, e1.id)
      refute MapSet.member?(pending, e2.id)
    end

    # #415 review (P1, BLOCKER): without the `expect_remote_id` generation guard,
    # `fence_episode_cleanup/2` would (a) silently flip an unrelated intent already holding one
    # of `episode_ids` in `download_intent_episodes` to `:cleanup_pending`, and (b) crash trying
    # to insert a SECOND `download_intent_episodes` row for the SAME episode_id (the carrier
    # insert), violating `unique_index(:episode_id)` — since two intents can never claim one
    # episode. Simulates the same race as the movie clobber test: a concurrent re-grab already
    # reserved this episode between the tick's import commit and the post-commit fence call.
    test "an episode-reservation conflict is never hijacked or crashed; the grab's download still gets a one-shot removal" do
      enable()
      {_series, season} = series_tree()
      e1 = episode(season, 5)

      race_intent =
        %Intent{}
        |> Intent.changeset(%{
          operation_key: Ecto.UUID.generate(),
          kind: :episode,
          target_id: e1.id,
          episode_ids: [e1.id],
          protocol: :usenet,
          release: %{"title" => "Show S01E05 Better"},
          status: :submitted,
          remote_id: "nzo-new-ep"
        })
        |> Repo.insert!()

      {:ok, _reservation} =
        %IntentEpisode{}
        |> IntentEpisode.changeset(%{intent_id: race_intent.id, episode_id: e1.id})
        |> Repo.insert()

      parent = self()

      stub(Cinder.Download.SabnzbdClientMock, :remove, fn id, opts ->
        send(parent, {:removed, id, opts})
        :ok
      end)

      spec = %{
        remote_id: "nzo-old-ep",
        protocol: :usenet,
        title: "Show S01E05",
        episode_ids: [e1.id]
      }

      assert :ok =
               SourceRemoval.remove_after_import(:usenet, "nzo-old-ep", "/dl/Show.S01E05.mkv",
                 fence: {:episode, [e1.id], spec}
               )

      assert_receive {:removed, "nzo-old-ep", [delete_files: true]}

      assert %Intent{status: :submitted, remote_id: "nzo-new-ep"} =
               Repo.get!(Intent, race_intent.id)

      refute Repo.get_by(Intent, kind: :episode, remote_id: "nzo-old-ep")
    end

    test "an unmatched video fences client and source removal across repeated ticks" do
      enable()
      {_series, season} = series_tree()
      e1 = episode(season, 1)
      e2 = episode(season, 2)
      {:ok, grab} = Catalog.create_grab("nzo-split-pack", :usenet, [e1.id, e2.id])
      {:ok, _} = Catalog.mark_grab_downloaded(grab, "/dl/split-pack")

      stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)

      stub(Cinder.Library.FilesystemMock, :find_files, fn _ ->
        {:ok,
         [
           {"/dl/split-pack/Show.S01E01.1080p.mkv", 3_000_000_000},
           {"/dl/split-pack/Show.S01E99.1080p.mkv", 1_000_000_000}
         ]}
      end)

      stub(Cinder.Library.FilesystemMock, :lstat, fn path ->
        cond do
          String.contains?(path, "/tmp/cinder-test-tv-library/") and not candidate_path?(path) ->
            {:error, :enoent}

          String.contains?(path, "S01E99") ->
            {:ok, %File.Stat{type: :regular, size: 1_000_000_000, inode: 99, major_device: 7}}

          true ->
            {:ok, %File.Stat{type: :regular, size: 3_000_000_000, inode: 1, major_device: 7}}
        end
      end)

      stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
      stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> :ok end)
      stub(Cinder.Library.FilesystemMock, :rename, fn _src, _dest -> :ok end)
      stub(Cinder.Library.FilesystemMock, :rm, fn _path -> :ok end)
      stub(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)
      echo_remove(Cinder.Download.SabnzbdClientMock)
      echo_rm_rf()

      start_supervised!({TvPoller, interval: 60_000})
      assert :ok = TvPoller.poll()

      assert Repo.get!(Episode, e1.id).file_path =~ "S01E01"
      assert Repo.get!(Episode, e2.id).grab_id == grab.id
      assert Repo.aggregate(from(f in GrabFile, where: f.grab_id == ^grab.id), :count) == 1
      refute_receive {:removed, "nzo-split-pack", _opts}
      refute_receive {:rm_rf, "/dl/split-pack"}

      assert :ok = TvPoller.poll()
      assert Repo.aggregate(from(f in GrabFile, where: f.grab_id == ^grab.id), :count) == 1
      refute_receive {:removed, "nzo-split-pack", _opts}
      refute_receive {:rm_rf, "/dl/split-pack"}
    end

    test "a provable policy mismatch is a discard: deletes its download-side source" do
      enable()
      enable_media_info()
      {_series, season} = series_tree()
      e1 = episode(season, 1)
      source = "/dl/Show.S01E01.1080p.mkv"
      grab = tv_policy_grab(e1, source, "[Group] Show S01E01 [1080p]")

      stub(Cinder.Library.FilesystemMock, :dir?, fn ^source -> false end)

      stub(Cinder.Library.FilesystemMock, :lstat, fn ^source ->
        {:ok,
         %File.Stat{
           type: :regular,
           size: 2_000_000_000,
           major_device: 1,
           inode: 116,
           mtime: {{2026, 7, 13}, {12, 0, 0}}
         }}
      end)

      expect(Cinder.Library.MediaInfoMock, :probe_policy, fn ^source ->
        {:ok, %{audio: ["ja"], subtitles: [], audio_unknown?: false, subtitle_unknown?: false}}
      end)

      echo_remove(Cinder.Download.SabnzbdClientMock)
      echo_rm_rf()
      start_supervised!({TvPoller, interval: 60_000})

      assert :ok = TvPoller.poll()

      refute Repo.get(Grab, grab.id)
      assert Repo.reload!(e1).grab_id == nil

      assert_receive {:rm_rf, ^source}
      assert_receive {:removed, "nzo-tv-reject", [delete_files: true]}
    end
  end

  # #684: a release the pollers blocklist (parked TV grab, reverted movie upgrade) leaves its
  # download behind — nothing owns it, and the Cleaner never reaped a completed one. The client job
  # and payload are removed under the same rule as a successful import (usenet + `move_on_import`).
  describe "rejected downloads (#684)" do
    defp unmatched_pack_grab(protocol, download_id, content_path) do
      {_series, season} = series_tree()
      e1 = episode(season, 1)
      {:ok, grab} = Catalog.create_grab(download_id, protocol, [e1.id], "Show.S01.Pack-GRP")
      {:ok, _} = Catalog.mark_grab_downloaded(grab, content_path)

      # No file in the pack matches the wanted episode -> :no_files_matched (blocklists + parks).
      stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)

      stub(Cinder.Library.FilesystemMock, :find_files, fn _ ->
        {:ok, [{Path.join(content_path, "Show.S01E99.mkv"), 3_000_000_000}]}
      end)

      {grab, e1}
    end

    # A downloaded grab on its last import attempt whose folder listing fails: a park that blocks
    # nothing (`:eacces` is not one of `Watch.failure?/1`'s codes).
    defp transient_park_grab(protocol, download_id, content_path) do
      {series, season} = series_tree()
      e1 = episode(season, 1)
      {:ok, grab} = Catalog.create_grab(download_id, protocol, [e1.id], "Show.S01.Pack-GRP")
      {:ok, _} = Catalog.mark_grab_downloaded(grab, content_path)
      Repo.update_all(from(g in Grab, where: g.id == ^grab.id), set: [download_attempts: 9])

      stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)
      stub(Cinder.Library.FilesystemMock, :find_files, fn _ -> {:error, :eacces} end)
      {grab, series}
    end

    # A downloaded usenet pack on its last import attempt whose one video stages, then fails to
    # commit: the sidecar listing that `StagedImport.place_video/5` runs after the stage is
    # prepared moves every prepared stage back to `:preparing`, so the writer's
    # `ImportStage.mark_committed!/1` refuses with `:stale_import_stage`.
    # `:anime` builds a resolved anime-mapping grab instead, whose writer is `finish_grab/3`.
    defp failing_commit_grab(download_id, content_path, kind \\ :standard) do
      {_series, season} = series_tree()
      e1 = episode(season, 1)
      grab = downloaded_usenet_grab(kind, e1, download_id, content_path)
      Repo.update_all(from(g in Grab, where: g.id == ^grab.id), set: [download_attempts: 9])
      video = {Path.join(content_path, "Show.S01E01.1080p.mkv"), 3_000_000_000}

      stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)

      stub(Cinder.Library.FilesystemMock, :find_files, fn ^content_path ->
        Repo.update_all(from(s in ImportStage, where: s.state == :prepared),
          set: [state: :preparing]
        )

        {:ok, [video]}
      end)

      stub(Cinder.Library.FilesystemMock, :lstat, fn path ->
        if candidate_path?(path) or not String.starts_with?(path, "/tmp/cinder-test-tv-library/"),
          do:
            {:ok,
             %File.Stat{
               type: :regular,
               size: 3_000_000_000,
               inode: 1,
               major_device: 1,
               mtime: {{2026, 7, 13}, {12, 0, 0}}
             }},
          else: {:error, :enoent}
      end)

      stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
      stub(Cinder.Library.FilesystemMock, :chmod, fn _path, _mode -> :ok end)
      stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> :ok end)
      stub(Cinder.Library.FilesystemMock, :rename, fn _src, _dest -> :ok end)
      stub(Cinder.Library.FilesystemMock, :rm, fn _path -> :ok end)
      stub(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)
      {grab, e1}
    end

    defp downloaded_usenet_grab(:standard, episode, download_id, content_path) do
      {:ok, grab} = Catalog.create_grab(download_id, :usenet, [episode.id], "Show.S01.Pack-GRP")
      {:ok, grab} = Catalog.mark_grab_downloaded(grab, content_path)
      grab
    end

    defp downloaded_usenet_grab(:anime, episode, download_id, content_path) do
      grab =
        Repo.insert!(%Grab{
          download_id: download_id,
          download_protocol: :usenet,
          release_title: "Show.S01.Pack-GRP",
          content_path: content_path,
          mapping_snapshot: anime_snapshot(episode),
          mapping_status: :resolved
        })

      Repo.update_all(from(e in Episode, where: e.id == ^episode.id), set: [grab_id: grab.id])
      grab
    end

    defp upgrading_movie(tmdb_id, protocol, download_id) do
      movie_fixture(%{
        tmdb_id: tmdb_id,
        title: "M",
        status: :upgrading,
        download_id: download_id,
        download_protocol: protocol,
        release_title: "Bad.1080p-GRP",
        file_path: "/lib/M (2020)/M (2020).mkv"
      })
    end

    # The replacement download yields no video file -> :no_video_file, a permanent import error.
    defp stub_no_video_file_download(mock, download_id, content_path) do
      stub(mock, :status, fn ^download_id ->
        {:ok, %{state: :completed, content_path: content_path}}
      end)

      stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)

      stub(Cinder.Library.FilesystemMock, :find_files, fn _ ->
        {:ok, [{Path.join(content_path, "readme.nfo"), 12}]}
      end)
    end

    # Client/payload removals are swallowed by `SourceRemoval.best_effort_remove/2` and
    # `best_effort_delete_source/1`, so a mock that raises can't prove a "keeps" test: record
    # every removal and refute the messages.
    defp record_removals(mock) do
      echo_remove(mock)
      echo_rm_rf()
    end

    defp refute_removals do
      refute_received {:removed, _id, _opts}
      refute_received {:rm_rf, _path}
    end

    test "a usenet grab parked :no_files_matched leaves a cleanup intent and its payload is deleted" do
      enable()
      {grab, e1} = unmatched_pack_grab(:usenet, "nzo-parked", "/dl/parked-pack")
      # A failing client keeps the fenced intent visible; the payload goes regardless.
      stub(Cinder.Download.SabnzbdClientMock, :remove, fn _id, _opts -> {:error, :timeout} end)
      echo_rm_rf()
      start_supervised!({TvPoller, interval: 60_000})

      assert :ok = TvPoller.poll()

      refute Repo.get(Grab, grab.id)

      assert %Intent{status: :cleanup_pending, protocol: :usenet, episode_ids: [episode_id]} =
               Repo.get_by!(Intent, remote_id: "nzo-parked")

      assert episode_id == e1.id
      assert_receive {:rm_rf, "/dl/parked-pack"}
    end

    test "a usenet grab parked :no_files_matched removes its client job and payload" do
      enable()
      unmatched_pack_grab(:usenet, "nzo-parked-2", "/dl/parked-pack-2")
      echo_remove(Cinder.Download.SabnzbdClientMock)
      echo_rm_rf()
      start_supervised!({TvPoller, interval: 60_000})

      assert :ok = TvPoller.poll()

      assert_receive {:removed, "nzo-parked-2", [delete_files: true]}
      assert_receive {:rm_rf, "/dl/parked-pack-2"}
      refute Repo.get_by(Intent, remote_id: "nzo-parked-2")
    end

    test "a torrent grab parked :no_files_matched keeps its payload and keeps seeding" do
      enable()
      {grab, _e1} = unmatched_pack_grab(:torrent, "hash-parked", "/dl/seeding-pack")
      record_removals(Cinder.Download.ClientMock)
      start_supervised!({TvPoller, interval: 60_000})

      assert :ok = TvPoller.poll()

      refute Repo.get(Grab, grab.id)
      assert Repo.all(Intent) == []
      refute_removals()
    end

    test "a usenet grab parked :no_files_matched keeps its payload while move_on_import is off" do
      unmatched_pack_grab(:usenet, "nzo-off", "/dl/off-pack")
      record_removals(Cinder.Download.SabnzbdClientMock)
      start_supervised!({TvPoller, interval: 60_000})

      assert :ok = TvPoller.poll()

      assert Repo.all(Intent) == []
      refute_removals()
    end

    test "a usenet upgrade reverted on a permanent import error leaves a cleanup intent and its payload is deleted" do
      enable()
      movie = upgrading_movie(61, :usenet, "nzo-up-bad")
      source = "/downloads/cinder-bad"
      stub_no_video_file_download(Cinder.Download.SabnzbdClientMock, "nzo-up-bad", source)
      stub(Cinder.Download.SabnzbdClientMock, :remove, fn _id, _opts -> {:error, :timeout} end)
      echo_rm_rf()
      start_supervised!({Poller, interval: 60_000})

      assert :ok = Poller.poll()

      assert %Movie{status: :available, download_id: nil, file_path: "/lib/M (2020)/M (2020).mkv"} =
               Repo.get!(Movie, movie.id)

      assert %Intent{status: :cleanup_pending, protocol: :usenet} =
               Repo.get_by!(Intent, remote_id: "nzo-up-bad")

      assert_receive {:rm_rf, ^source}
      refute_receive {:rm_rf, "/lib/M (2020)/M (2020).mkv"}
    end

    test "a usenet upgrade reverted on a permanent import error removes its client job" do
      enable()
      upgrading_movie(62, :usenet, "nzo-up-bad-2")
      source = "/downloads/cinder-bad-2"
      stub_no_video_file_download(Cinder.Download.SabnzbdClientMock, "nzo-up-bad-2", source)
      echo_remove(Cinder.Download.SabnzbdClientMock)
      echo_rm_rf()
      start_supervised!({Poller, interval: 60_000})

      assert :ok = Poller.poll()

      assert_receive {:removed, "nzo-up-bad-2", [delete_files: true]}
      assert_receive {:rm_rf, ^source}
    end

    test "a torrent upgrade reverted on a permanent import error keeps its payload and keeps seeding" do
      enable()
      movie = upgrading_movie(63, :torrent, "hash-up-bad")
      stub_no_video_file_download(Cinder.Download.ClientMock, "hash-up-bad", "/downloads/seeding")
      record_removals(Cinder.Download.ClientMock)
      start_supervised!({Poller, interval: 60_000})

      assert :ok = Poller.poll()

      assert %Movie{status: :available, download_id: nil} = Repo.get!(Movie, movie.id)
      assert Repo.all(Intent) == []
      refute_removals()
    end

    # #1588: a park that blocks nothing still removes the payload. A re-pick of the release
    # downloads it again into a new `<title>.cinder-<key>` folder, so the kept copy was never
    # imported. One such park leaves the release grabbable.
    test "a usenet grab parked after a transient import error removes its job and payload" do
      enable()
      {grab, series} = transient_park_grab(:usenet, "nzo-transient", "/dl/transient-pack")
      record_removals(Cinder.Download.SabnzbdClientMock)
      start_supervised!({TvPoller, interval: 60_000})

      assert :ok = TvPoller.poll()

      refute Repo.get(Grab, grab.id)
      assert Catalog.blocked_release_titles_for_series(series.id) == []
      assert_received {:removed, "nzo-transient", [delete_files: true]}
      assert_received {:rm_rf, "/dl/transient-pack"}
      refute Repo.get_by(Intent, remote_id: "nzo-transient")
      assert [%BlockedRelease{reason: "park_strike"}] = Repo.all(BlockedRelease)
    end

    test "a usenet grab parked after a transient import error keeps its payload while move_on_import is off" do
      {grab, _series} = transient_park_grab(:usenet, "nzo-transient-off", "/dl/transient-off")
      record_removals(Cinder.Download.SabnzbdClientMock)
      start_supervised!({TvPoller, interval: 60_000})

      assert :ok = TvPoller.poll()

      refute Repo.get(Grab, grab.id)
      assert Repo.all(Intent) == []
      refute_removals()
      assert [%BlockedRelease{reason: "park_strike"}] = Repo.all(BlockedRelease)
    end

    test "a torrent grab parked after a transient import error keeps its payload and keeps seeding" do
      enable()
      {grab, _series} = transient_park_grab(:torrent, "hash-transient", "/dl/transient-seed")
      record_removals(Cinder.Download.ClientMock)
      start_supervised!({TvPoller, interval: 60_000})

      assert :ok = TvPoller.poll()

      refute Repo.get(Grab, grab.id)
      assert Repo.all(Intent) == []
      refute_removals()
      assert [%BlockedRelease{reason: "park_strike"}] = Repo.all(BlockedRelease)
    end

    # `:no_client` comes from the download watch, before the grab has a content path. With the
    # usenet client gone, a removal attempt shows only as the cleanup intent the park would fence,
    # so the intent check is the one that fails when the park tries a removal.
    test "a usenet grab with no content path parked :no_client makes no removal and leaves no cleanup intent" do
      enable()
      {_series, season} = series_tree()
      e1 = episode(season, 1)
      {:ok, grab} = Catalog.create_grab("nzo-no-client", :usenet, [e1.id], "Show.S01E01-GRP")
      Repo.update_all(from(g in Grab, where: g.id == ^grab.id), set: [download_attempts: 9])
      clients = Application.fetch_env!(:cinder, :download_clients)
      ConfigCase.put_env(:download_clients, Map.delete(clients, :usenet))
      echo_rm_rf()
      start_supervised!({TvPoller, interval: 60_000})

      assert :ok = TvPoller.poll()

      refute Repo.get(Grab, grab.id)
      assert Repo.reload!(e1).grab_id == nil
      assert Repo.all(Intent) == []
      refute_received {:rm_rf, _path}
      # It still counts as a park that blocked nothing.
      assert [%BlockedRelease{reason: "park_strike"}] = Repo.all(BlockedRelease)
    end

    # The commit's writer refuses (`:stale_import_stage`), so `StagedImport.commit/2` rolls the
    # staged file back before the park. The payload goes only after that rollback: when it runs,
    # no import stage is left in the journal.
    test "a usenet grab parked on a failed commit deletes its payload only once its staged file is rolled back" do
      enable()
      {grab, e1} = failing_commit_grab("nzo-commit", "/dl/commit-pack")
      parent = self()

      stub(Cinder.Library.FilesystemMock, :rm_rf, fn path ->
        send(parent, {:rm_rf, path, Repo.aggregate(ImportStage, :count)})
        {:ok, [path]}
      end)

      echo_remove(Cinder.Download.SabnzbdClientMock)
      start_supervised!({TvPoller, interval: 60_000})

      log = capture_log(fn -> assert :ok = TvPoller.poll() end)

      assert log =~ "exhausted after 10: {:commit_grab_imports, :stale_import_stage}"
      refute Repo.get(Grab, grab.id)
      assert Repo.reload!(e1).file_path == nil
      assert_received {:rm_rf, "/dl/commit-pack", 0}
      assert_received {:removed, "nzo-commit", [delete_files: true]}
    end

    test "an anime usenet grab parked on a failed finish deletes its payload only once its staged file is rolled back" do
      enable()
      {grab, e1} = failing_commit_grab("nzo-finish", "/dl/finish-pack", :anime)
      parent = self()

      stub(Cinder.Library.FilesystemMock, :rm_rf, fn path ->
        send(parent, {:rm_rf, path, Repo.aggregate(ImportStage, :count)})
        {:ok, [path]}
      end)

      echo_remove(Cinder.Download.SabnzbdClientMock)
      start_supervised!({TvPoller, interval: 60_000})

      log = capture_log(fn -> assert :ok = TvPoller.poll() end)

      assert log =~ "exhausted after 10: {:finish_grab, :stale_import_stage}"
      refute Repo.get(Grab, grab.id)
      assert Repo.reload!(e1).file_path == nil
      assert_received {:rm_rf, "/dl/finish-pack", 0}
      assert_received {:removed, "nzo-finish", [delete_files: true]}
    end

    test "an anime usenet grab parked on a failed finish keeps its payload while its staged file's rollback is pending" do
      enable()
      {grab, _e1} = failing_commit_grab("nzo-finish-stuck", "/dl/finish-stuck", :anime)
      record_removals(Cinder.Download.SabnzbdClientMock)

      stub(Cinder.Library.FilesystemMock, :rm, fn _path ->
        if Repo.exists?(from(s in ImportStage, where: s.state == :rolling_back)),
          do: {:error, :eio},
          else: :ok
      end)

      start_supervised!({TvPoller, interval: 60_000})

      log = capture_log(fn -> assert :ok = TvPoller.poll() end)

      assert log =~ "exhausted after 10: {:finish_grab, :stale_import_stage}"
      refute Repo.get(Grab, grab.id)
      assert [%ImportStage{state: :rolling_back, last_error: "eio"}] = Repo.all(ImportStage)
      assert Repo.all(Intent) == []
      refute_removals()
    end

    # The same failed commit, but the staged file's rollback fails too: the file stays in the
    # library until `StagedImport.reconcile/0` finishes it, so the park keeps the payload and
    # the client job (whose removal would delete the payload as well).
    test "a usenet grab parked on a failed commit keeps its payload while its staged file's rollback is pending" do
      enable()
      {grab, _e1} = failing_commit_grab("nzo-commit-stuck", "/dl/commit-stuck")
      record_removals(Cinder.Download.SabnzbdClientMock)

      # Only the rollback, which claims the stage as `:rolling_back` first, gets the error.
      stub(Cinder.Library.FilesystemMock, :rm, fn _path ->
        if Repo.exists?(from(s in ImportStage, where: s.state == :rolling_back)),
          do: {:error, :eio},
          else: :ok
      end)

      start_supervised!({TvPoller, interval: 60_000})

      log = capture_log(fn -> assert :ok = TvPoller.poll() end)

      assert log =~ "exhausted after 10: {:commit_grab_imports, :stale_import_stage}"
      refute Repo.get(Grab, grab.id)
      assert [%ImportStage{state: :rolling_back, last_error: "eio"}] = Repo.all(ImportStage)
      assert Repo.all(Intent) == []
      refute_removals()
    end

    # The rollback an earlier attempt left pending blocks the next attempt's staging
    # (`:import_stage_busy` on the same destination), which then parks having placed nothing. The
    # earlier stage's file is still in the library, so that park keeps the payload too.
    test "a usenet grab parked one attempt after its rollback failed keeps its payload while that rollback is pending" do
      enable()
      {grab, _e1} = failing_commit_grab("nzo-earlier-stuck", "/dl/earlier-stuck")
      Repo.update_all(from(g in Grab, where: g.id == ^grab.id), set: [download_attempts: 8])
      record_removals(Cinder.Download.SabnzbdClientMock)

      stub(Cinder.Library.FilesystemMock, :rm, fn _path ->
        if Repo.exists?(from(s in ImportStage, where: s.state == :rolling_back)),
          do: {:error, :eio},
          else: :ok
      end)

      start_supervised!({TvPoller, interval: 60_000})

      capture_log(fn -> assert :ok = TvPoller.poll() end)
      assert %Grab{download_attempts: 9} = Repo.get(Grab, grab.id)
      assert [%ImportStage{state: :rolling_back}] = Repo.all(ImportStage)

      log = capture_log(fn -> assert :ok = TvPoller.poll() end)

      assert log =~ "exhausted after 10: :import_stage_busy"
      refute Repo.get(Grab, grab.id)
      assert [%ImportStage{state: :rolling_back, last_error: "eio"}] = Repo.all(ImportStage)
      assert Repo.all(Intent) == []
      refute_removals()
    end

    # A staging error the stager rolls back itself (`Library.stage_episodes/3`), whose cleanup of
    # the half-placed file fails: no stager hands that stage back, and the park keeps the payload.
    test "a usenet grab parked on a staging error keeps its payload while the half-staged file's cleanup is pending" do
      enable()
      {grab, _e1} = failing_commit_grab("nzo-stage-stuck", "/dl/stage-stuck")
      record_removals(Cinder.Download.SabnzbdClientMock)

      stub(Cinder.Library.FilesystemMock, :rm, fn path ->
        if String.starts_with?(path, "/tmp/cinder-test-tv-library/"),
          do: {:error, :eio},
          else: :ok
      end)

      start_supervised!({TvPoller, interval: 60_000})

      log = capture_log(fn -> assert :ok = TvPoller.poll() end)

      assert log =~ "exhausted after 10: :eio"
      refute Repo.get(Grab, grab.id)
      assert [%ImportStage{state: :preparing, last_error: "eio"}] = Repo.all(ImportStage)
      assert Repo.all(Intent) == []
      refute_removals()
    end

    test "a usenet upgrade reverted after a transient import error keeps its job and payload" do
      enable()
      movie = upgrading_movie(64, :usenet, "nzo-up-transient")
      {:ok, _} = seed_movie_state(movie, %{status: :upgrading, import_attempts: 9})

      stub_no_video_file_download(
        Cinder.Download.SabnzbdClientMock,
        "nzo-up-transient",
        "/downloads/cinder-transient"
      )

      stub(Cinder.Library.FilesystemMock, :find_files, fn _ -> {:error, :eacces} end)
      record_removals(Cinder.Download.SabnzbdClientMock)
      start_supervised!({Poller, interval: 60_000})

      assert :ok = Poller.poll()

      assert %Movie{status: :available, download_id: nil} = Repo.get!(Movie, movie.id)
      assert Catalog.blocked_release_titles(Repo.get!(Movie, movie.id)) == []
      refute_removals()
    end
  end
end
