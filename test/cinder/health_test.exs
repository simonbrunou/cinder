defmodule Cinder.HealthTest do
  use Cinder.DataCase, async: false

  import Mox

  alias Cinder.Health
  alias Cinder.Library.SidecarQuarantine

  setup :verify_on_exit!

  setup do
    roots = [:books_library_path, :audiobooks_library_path]
    saved = Map.new(roots, &{&1, Application.get_env(:cinder, &1)})
    Enum.each(roots, &Application.delete_env(:cinder, &1))

    on_exit(fn -> restore_env(saved) end)

    :ok
  end

  defp restore_env(saved) do
    Enum.each(saved, fn
      {key, nil} -> Application.delete_env(:cinder, key)
      {key, value} -> Application.put_env(:cinder, key, value)
    end)
  end

  defp with_env(key, value) do
    saved = %{key => Application.get_env(:cinder, key)}
    Application.put_env(:cinder, key, value)
    on_exit(fn -> restore_env(saved) end)
  end

  defp stub_books_providers do
    stub(Cinder.Books.PrimaryMetadataMock, :provider, fn -> :openlibrary end)
    stub(Cinder.Books.SecondaryMetadataMock, :provider, fn -> :hardcover end)
  end

  defp stub_check_all_services do
    stub(Cinder.Catalog.TMDBMock, :health, fn -> :ok end)
    stub(Cinder.Acquisition.IndexerMock, :health, fn -> :ok end)
    stub_books_providers()
    stub(Cinder.Books.PrimaryMetadataMock, :health, fn -> :ok end)
    stub(Cinder.Books.SecondaryMetadataMock, :health, fn -> :ok end)
    stub(Cinder.Download.ClientMock, :health, fn -> {:error, :econnrefused} end)
    stub(Cinder.Download.SabnzbdClientMock, :health, fn -> :ok end)
    stub(Cinder.Library.MediaServerMock, :health, fn -> :ok end)
    stub(Cinder.Library.AudiobookServerMock, :health, fn -> :ok end)
    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :write_exclusive, fn _, _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :rm, fn _ -> :ok end)
  end

  defp row(rows, id), do: Enum.find(rows, &(&1.id == id))

  describe "targets/1" do
    test "every probe target has one unique id and sits in a settings group, in group order" do
      targets = Health.targets()
      ids = Enum.map(targets, & &1.id)
      group_order = Enum.map(Cinder.Settings.groups(), &elem(&1, 0))

      assert ids == Enum.uniq(ids)
      assert Enum.all?(ids, &(&1 =~ ~r/^[a-z][a-z0-9_]*$/))
      assert Enum.all?(targets, &(&1.group in group_order))

      positions = Enum.map(targets, &Enum.find_index(group_order, fn g -> g == &1.group end))
      assert positions == Enum.sort(positions)
    end

    test "lists each group's Test buttons, the books providers included" do
      ids = &(Health.targets(group: &1) |> Enum.map(fn target -> target.id end))

      assert ids.(:tmdb) == ["tmdb"]
      assert ids.(:indexer) == ["indexer"]
      assert ids.(:migration) == ["radarr", "sonarr", "readarr"]
      assert ids.(:download) == ["torrent", "usenet"]
      assert ids.(:media_server) == ["media_server"]
      assert ids.(:audiobook_server) == ["audiobook_server"]

      assert ids.(:library) ==
               [
                 "movies_library",
                 "tv_library",
                 "ebook_library",
                 "audiobook_library",
                 "media_info"
               ]

      assert ids.(:subtitles) == ["subtitles"]
      assert ids.(:books) == ["openlibrary", "hardcover"]
      assert ids.(:notifications) == ["discord"]
      assert ids.(:releases) == []
    end

    test "setup requires TMDB, the indexer, the media server and every library root, plus one download client" do
      ids = &(Health.targets(setup: &1) |> Enum.map(fn target -> target.id end))

      assert ids.(:required) == [
               "tmdb",
               "indexer",
               "media_server",
               "movies_library",
               "tv_library",
               "ebook_library",
               "audiobook_library"
             ]

      assert ids.(:any) == ["torrent", "usenet"]
    end

    test "the dashboard names the adapter only where the operator picks it" do
      ids = Enum.map(Health.targets(names_adapter: true), & &1.id)

      assert ids == ["torrent", "usenet", "media_server"]
    end

    test "every production books provider has a target" do
      for provider <- [Cinder.Books.Metadata.OpenLibrary, Cinder.Books.Metadata.Hardcover] do
        assert [%{probe: {:books_metadata, _}}] =
                 Health.targets(probe: {:books_metadata, provider.provider()})
      end
    end
  end

  describe "check/1" do
    test "an id no target has is :unknown_target" do
      for id <- ["nope", "", "tmdb "], do: assert(Health.check(id) == {:error, :unknown_target})
    end

    test "probes the configured adapter of each service target" do
      stub(Cinder.Catalog.TMDBMock, :health, fn -> :ok end)
      stub(Cinder.Acquisition.IndexerMock, :health, fn -> {:error, :down} end)
      stub(Cinder.Library.MediaServerMock, :health, fn -> :ok end)
      stub(Cinder.Library.AudiobookServerMock, :health, fn -> {:warning, :slow} end)
      stub(Cinder.Download.ClientMock, :health, fn -> :ok end)
      stub(Cinder.Download.SabnzbdClientMock, :health, fn -> {:error, :econnrefused} end)

      assert Health.check("tmdb") == :ok
      assert Health.check("indexer") == {:error, :down}
      assert Health.check("media_server") == :ok
      assert Health.check("audiobook_server") == {:warning, :slow}
      assert Health.check("torrent") == :ok
      assert Health.check("usenet") == {:error, :econnrefused}
    end

    test "a service with no adapter configured is not configured" do
      with_env(:audiobook_server, nil)
      with_env(:download_clients, %{usenet: Cinder.Download.SabnzbdClientMock})

      assert Health.check("audiobook_server") == {:error, :not_configured}
      assert Health.check("torrent") == {:error, :not_configured}
    end

    test "probes the books provider whose provider/0 matches the target" do
      stub_books_providers()
      stub(Cinder.Books.PrimaryMetadataMock, :health, fn -> :ok end)
      stub(Cinder.Books.SecondaryMetadataMock, :health, fn -> {:error, :timeout} end)

      assert Health.check("openlibrary") == :ok
      assert Health.check("hardcover") == {:error, :timeout}
    end

    test "a books provider no configured adapter answers to is not configured" do
      stub(Cinder.Books.PrimaryMetadataMock, :provider, fn -> :openlibrary end)
      stub(Cinder.Books.SecondaryMetadataMock, :provider, fn -> :openlibrary end)
      stub(Cinder.Books.PrimaryMetadataMock, :health, fn -> :ok end)

      assert Health.check("hardcover") == {:error, :not_configured}
    end

    test "a probe exceeding the timeout budget reports :timeout once the budget expires" do
      with_env(:health_probe_timeout_ms, 200)

      stub(Cinder.Acquisition.IndexerMock, :health, fn ->
        Process.sleep(5_000)
        :ok
      end)

      started = System.monotonic_time(:millisecond)
      assert Health.check("indexer") == {:error, :timeout}
      elapsed = System.monotonic_time(:millisecond) - started

      # Waited out, the probe answers `:ok` after 5 s. The check gives up at the 200 ms budget,
      # and the upper bound leaves a loaded CPU its margin.
      assert elapsed >= 200
      assert elapsed < 1_000
    end

    test "a failure while resolving the adapter is an error status, never a raise" do
      stub(Cinder.Books.PrimaryMetadataMock, :provider, fn -> raise "boom" end)

      assert {:error, %RuntimeError{message: "boom"}} = Health.check("openlibrary")
    end

    test "probes each configured migration source" do
      expect(Cinder.Library.RadarrMigrationSourceMock, :health, fn -> :ok end)
      expect(Cinder.Library.SonarrMigrationSourceMock, :health, fn -> {:error, :down} end)
      expect(Cinder.Library.ReadarrMigrationSourceMock, :health, fn -> :ok end)

      assert Health.check("radarr") == :ok
      assert Health.check("sonarr") == {:error, :down}
      assert Health.check("readarr") == :ok
    end

    test "a migration source outside the configured map is not configured" do
      with_env(:migration_sources, %{})

      assert Health.check("radarr") == {:error, :not_configured}
    end

    test "validates the Discord webhook (GET)" do
      Req.Test.stub(Cinder.DiscordStub, fn conn -> Req.Test.json(conn, %{"id" => "1"}) end)
      assert :ok = Health.check("discord")
    end

    test "subtitles are not configured with no api key" do
      # Deliberately no config mutation: the check reads the *resolved* :subtitles_provider
      # (Cinder.Subtitles.ProviderMock in test — config/test.exs), which never has an :api_key
      # configured, so this is already :not_configured. Mutating the real
      # Cinder.Subtitles.Provider.OpenSubtitles module's global Application env here raced this
      # suite against Cinder.Subtitles.Provider.OpenSubtitlesTest (async: true), which relies on
      # that module's config (req_options' Req.Test plug) staying intact for the whole run — the
      # window let real requests through to the live OpenSubtitles.com API.
      assert Health.check("subtitles") == {:error, :not_configured}
    end

    test "media info is not configured when ffprobe verification is disabled" do
      # config/test.exs sets `media_info: nil` for the whole suite. The "delegates to the
      # configured impl's health/0" path is covered in ffprobe_test.exs (async: false), which
      # already owns mutating :ffprobe_bin/:media_info safely.
      assert Health.check("media_info") == {:error, :not_configured}
    end

    test "a library root is :ok when the library dir is writable" do
      stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
      stub(Cinder.Library.FilesystemMock, :write_exclusive, fn _, _ -> :ok end)
      stub(Cinder.Library.FilesystemMock, :rm, fn _ -> :ok end)

      assert Health.check("movies_library") == :ok
      assert Health.check("tv_library") == :ok
    end

    test "a library root surfaces a filesystem error" do
      stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> {:error, :eacces} end)

      assert Health.check("movies_library") == {:error, :eacces}
      assert Health.check("tv_library") == {:error, :eacces}
    end

    test "an unset library root is not configured" do
      assert Health.check("ebook_library") == {:error, :not_configured}
    end

    # Each kind's probe writes into the root its own definition targets (ebooks: books_library_path),
    # and a blank root reads as unset there too, as the importer reads it.
    test "each kind's library probe checks that kind's configured root" do
      parent = self()

      stub(Cinder.Library.FilesystemMock, :mkdir_p, fn path ->
        send(parent, {:mkdir_p, path})
        :ok
      end)

      stub(Cinder.Library.FilesystemMock, :write_exclusive, fn _, _ -> :ok end)
      stub(Cinder.Library.FilesystemMock, :rm, fn _ -> :ok end)

      for {id, key} <- [
            {"movies_library", :movies_library_path},
            {"tv_library", :tv_library_path},
            {"ebook_library", :books_library_path},
            {"audiobook_library", :audiobooks_library_path}
          ] do
        with_env(key, "/srv/probe/#{key}")
        assert Health.check(id) == :ok
        assert_received {:mkdir_p, path}
        assert path == "/srv/probe/#{key}"

        with_env(key, "  ")
        assert Health.check(id) == {:error, :not_configured}
      end
    end

    test "an existing, unwritable library directory is unhealthy" do
      # mkdir_p on an existing directory always returns :ok even when the app cannot create
      # files or subdirectories in it (a read-only mount, a Docker UID/GID mismatch) — the
      # writability check must go further than that.
      stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
      stub(Cinder.Library.FilesystemMock, :write_exclusive, fn _, _ -> {:error, :eacces} end)
      assert Health.check("movies_library") == {:error, :eacces}
    end

    test "a library root check removes its disposable probe entry" do
      stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)

      parent = self()

      expect(Cinder.Library.FilesystemMock, :write_exclusive, fn path, "" ->
        send(parent, {:fs, :write_exclusive, path})
        :ok
      end)

      expect(Cinder.Library.FilesystemMock, :rm, fn path ->
        send(parent, {:fs, :rm, path})
        :ok
      end)

      assert Health.check("movies_library") == :ok
      # The probe runs in a task, so the callbacks report here. Each `assert_received` takes the
      # oldest matching message, so this also checks the write came before the removal.
      assert_received {:fs, first, path}
      assert_received {:fs, second, ^path}
      assert {first, second} == {:write_exclusive, :rm}
    end
  end

  describe "check_targets/1" do
    test "returns each target's own status by id, warnings and unwired targets included" do
      stub(Cinder.Catalog.TMDBMock, :health, fn -> :ok end)
      stub(Cinder.Acquisition.IndexerMock, :health, fn -> {:error, :down} end)
      stub(Cinder.Library.AudiobookServerMock, :health, fn -> {:warning, :slow} end)

      targets =
        Enum.flat_map(~w(tmdb indexer audiobook_server ebook_library), &Health.targets(id: &1))

      assert Health.check_targets(targets) == %{
               "tmdb" => :ok,
               "indexer" => {:error, :down},
               "audiobook_server" => {:warning, :slow},
               "ebook_library" => {:error, :not_configured}
             }
    end

    test "a probe exceeding the timeout budget reports :timeout without holding up the others" do
      with_env(:health_probe_timeout_ms, 200)
      stub(Cinder.Catalog.TMDBMock, :health, fn -> :ok end)

      stub(Cinder.Acquisition.IndexerMock, :health, fn ->
        Process.sleep(2_000)
        :ok
      end)

      targets = Health.targets(id: "tmdb") ++ Health.targets(id: "indexer")

      assert Health.check_targets(targets) == %{"tmdb" => :ok, "indexer" => {:error, :timeout}}
    end

    test "no targets is an empty map" do
      assert Health.check_targets([]) == %{}
    end
  end

  describe "check_all/0" do
    test "returns one row per dashboard target, in settings-group order" do
      stub_check_all_services()

      assert Health.check_all() == [
               %{id: "tmdb", label: "TMDB", adapter: nil, status: :ok},
               %{id: "indexer", label: "Prowlarr", adapter: nil, status: :ok},
               %{
                 id: "torrent",
                 label: "Torrent client",
                 adapter: "ClientMock",
                 status: {:error, :econnrefused}
               },
               %{
                 id: "usenet",
                 label: "Usenet client",
                 adapter: "SabnzbdClientMock",
                 status: :ok
               },
               %{
                 id: "media_server",
                 label: "Media server",
                 adapter: "MediaServerMock",
                 status: :ok
               },
               %{id: "audiobook_server", label: "Audiobookshelf", adapter: nil, status: :ok},
               %{id: "movies_library", label: "Movies library", adapter: nil, status: :ok},
               %{id: "tv_library", label: "TV library", adapter: nil, status: :ok},
               %{id: "openlibrary", label: "Open Library", adapter: nil, status: :ok},
               %{id: "hardcover", label: "Hardcover", adapter: nil, status: :ok}
             ]
    end

    test "a books metadata provider failure reports on its own row without affecting the others" do
      stub_check_all_services()
      stub(Cinder.Books.PrimaryMetadataMock, :health, fn -> {:error, :timeout} end)

      rows = Health.check_all()

      assert row(rows, "openlibrary").status == {:error, :timeout}
      assert row(rows, "hardcover").status == :ok
      assert row(rows, "tmdb").status == :ok
    end

    test "book library rows are omitted until their roots are configured" do
      stub_check_all_services()
      without_books = Health.check_all()

      refute row(without_books, "ebook_library")
      refute row(without_books, "audiobook_library")

      with_env(:books_library_path, "/media/books")
      with_books = Health.check_all()

      assert %{label: "Ebooks library", status: :ok} = ebook = row(with_books, "ebook_library")
      assert List.delete(with_books, ebook) == without_books
    end

    test "a download protocol with no client has no row" do
      stub_check_all_services()
      with_env(:download_clients, %{usenet: Cinder.Download.SabnzbdClientMock})

      rows = Health.check_all()

      refute row(rows, "torrent")
      assert row(rows, "usenet").status == :ok
    end

    test "migration sources and Discord have Test buttons but no dashboard row" do
      stub_check_all_services()
      ids = Enum.map(Health.check_all(), & &1.id)

      for id <- ~w(radarr sonarr readarr discord), do: refute(id in ids)
    end

    test "turns a raising impl into an error row instead of crashing" do
      stub_check_all_services()
      stub(Cinder.Acquisition.IndexerMock, :health, fn -> raise "boom" end)

      assert {:error, %RuntimeError{message: "boom"}} = row(Health.check_all(), "indexer").status
    end

    test "turns an exiting impl into an error row instead of crashing the task" do
      stub_check_all_services()
      stub(Cinder.Acquisition.IndexerMock, :health, fn -> exit(:boom) end)

      assert {:error, {:exit, :boom}} = row(Health.check_all(), "indexer").status
    end

    test "runs probes concurrently instead of paying their sum" do
      stub_check_all_services()
      sleep_ms = 200

      for mock <- [
            Cinder.Catalog.TMDBMock,
            Cinder.Acquisition.IndexerMock,
            Cinder.Books.PrimaryMetadataMock,
            Cinder.Books.SecondaryMetadataMock,
            Cinder.Library.MediaServerMock,
            Cinder.Library.AudiobookServerMock
          ] do
        stub(mock, :health, fn ->
          Process.sleep(sleep_ms)
          :ok
        end)
      end

      started = System.monotonic_time(:millisecond)
      Health.check_all()
      elapsed = System.monotonic_time(:millisecond) - started

      # Six probes at `sleep_ms` each cost `6 * sleep_ms` serially; concurrently the sweep costs
      # one `sleep_ms`. Assert well under half the serial sum so this stays deterministic on a
      # loaded CI box instead of chasing the concurrent figure exactly.
      assert elapsed < 3 * sleep_ms
    end

    test "a probe exceeding the timeout budget reports :timeout without blocking other rows" do
      stub_check_all_services()
      with_env(:health_probe_timeout_ms, 200)

      stub(Cinder.Acquisition.IndexerMock, :health, fn ->
        Process.sleep(2_000)
        :ok
      end)

      rows = Health.check_all()

      assert row(rows, "indexer").status == {:error, :timeout}
      assert row(rows, "tmdb").status == :ok
      assert row(rows, "media_server").status == :ok
    end

    test "a timed-out row still names the adapter the operator picked" do
      stub_check_all_services()
      with_env(:health_probe_timeout_ms, 200)

      stub(Cinder.Download.ClientMock, :health, fn ->
        Process.sleep(2_000)
        :ok
      end)

      assert %{status: {:error, :timeout}, adapter: "ClientMock"} =
               row(Health.check_all(), "torrent")
    end

    test "surfaces a 'Sidecar files' warning row for a retained sidecar whose file still exists" do
      stub_check_all_services()
      path = "/library/movies/Movie (2020)/.cinder-sidecar-quarantine-abc123"

      :ok =
        SidecarQuarantine.record("/library/movies/Movie (2020)/Movie.en.srt", path, "occupied")

      stub(Cinder.Library.FilesystemMock, :lstat, fn ^path -> {:ok, %File.Stat{}} end)

      assert %{label: "Sidecar files", status: {:warning, {:retained_sidecars, [^path]}}} =
               row(Health.check_all(), "sidecar_files")
    end

    test "no 'Sidecar files' row when nothing is recorded" do
      stub_check_all_services()

      refute row(Health.check_all(), "sidecar_files")
    end

    # Issue #585: a row survives its own file being cleaned up by hand only until the next
    # /dashboard mount notices it's gone — no filesystem walk ever rediscovers a stale row, so
    # nothing would prune it otherwise.
    test "prunes a row whose quarantine file no longer exists and never surfaces it" do
      stub_check_all_services()
      path = "/library/movies/Movie (2020)/.cinder-sidecar-quarantine-gone"

      :ok =
        SidecarQuarantine.record("/library/movies/Movie (2020)/Movie.en.srt", path, "occupied")

      stub(Cinder.Library.FilesystemMock, :lstat, fn ^path -> {:error, :enoent} end)

      refute row(Health.check_all(), "sidecar_files")
      assert Repo.all(SidecarQuarantine) == []
    end
  end
end
