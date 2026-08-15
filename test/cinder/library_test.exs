defmodule Cinder.LibraryTest do
  # In-test-process unit tests: expect + verify_on_exit!, no DB, no disk.
  use Cinder.DataCase, async: false

  import Mox
  import ExUnit.CaptureLog

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Grab, GrabFile, Movie, Season, Series}
  alias Cinder.Library
  alias Cinder.Library.ImportStage

  defmodule DisappearingPathPolicy do
    def source_file(path, _roots, _extensions, _opts) do
      calls = Application.fetch_env!(:cinder, :disappearing_path_policy_calls)
      call = Agent.get_and_update(calls, &{&1, &1 + 1})

      if call == 0, do: {:ok, Path.expand(path)}, else: {:error, :unsafe_source}
    end

    defdelegate destination(path, root, opts), to: Cinder.Test.PermissivePathPolicy
    defdelegate deletable_file(path, roots, opts), to: Cinder.Test.PermissivePathPolicy
    defdelegate deletable_source(path, roots, opts), to: Cinder.Test.PermissivePathPolicy
    defdelegate walk(path, opts), to: Cinder.Test.PermissivePathPolicy
  end

  setup :verify_on_exit!

  @lib "/tmp/cinder-test-library"
  @tv_lib "/tmp/cinder-test-tv-library"
  @gb 1_000_000_000
  @anime_fixture_path "test/support/fixtures/anime/import-v1.json"
  @external_resource @anime_fixture_path
  @anime_cases @anime_fixture_path |> File.read!() |> Jason.decode!() |> Map.fetch!("cases")

  # An in-memory episode with its season/series preloaded (what wanted_episodes/the poller pass).
  defp ep(id, ep_num, season_num \\ 1, series_attrs \\ []) do
    series = struct(%Series{title: "Show", year: 2008, tmdb_id: 1}, series_attrs)

    %Episode{
      id: id,
      episode_number: ep_num,
      season: %Season{season_number: season_num, series: series}
    }
  end

  # Commits a `stage_movie`/`stage_episodes` result the way production does: the DB write
  # (`Catalog.transition(..., import_stage_ids: ...)`) marks the journal row `:committed` before
  # `commit_stage/1` is allowed to run its post-commit effects — mirror that ordering here without
  # a full Catalog.transition, since these unit tests assert on the library layer only.
  defp commit!(stage) do
    ImportStage.mark_committed!(Library.stage_ids([stage]))
    Library.commit_stage(stage)
  end

  describe "inventory_anime_videos/1" do
    setup do
      saved_path_policy = Application.get_env(:cinder, :path_policy)
      saved_import_roots = Application.get_env(:cinder, :import_roots)

      Application.put_env(:cinder, :path_policy, Cinder.Library.PathPolicy)
      Application.put_env(:cinder, :import_roots, ["/downloads"])

      on_exit(fn ->
        restore_env(:path_policy, saved_path_policy)
        restore_env(:import_roots, saved_import_roots)
      end)

      :ok
    end

    test "inventories sorted relative video paths with stable file identities" do
      release = "/downloads/Frieren"
      season = "#{release}/Season 1"

      stats = %{
        "/" => dir_stat(1),
        "/downloads" => dir_stat(2),
        release => dir_stat(3),
        season => dir_stat(4),
        "#{season}/Frieren - 02.MP4" => file_stat(22, 20, {{2026, 7, 13}, {12, 2, 0}}),
        "#{season}/notes.txt" => file_stat(23, 5, {{2026, 7, 13}, {12, 3, 0}}),
        "#{season}/Frieren - 01.mkv" => file_stat(21, 10, {{2026, 7, 13}, {12, 1, 0}})
      }

      stub_virtual_tree(stats, %{
        release => ["Season 1"],
        season => ["Frieren - 02.MP4", "notes.txt", "Frieren - 01.mkv"]
      })

      assert {:ok, %{files: [first, second], folder?: true} = inventory} =
               Library.inventory_anime_videos(release)

      assert first == %{
               relative_path: "Season 1/Frieren - 01.mkv",
               identity: %{
                 size: 10,
                 major_device: 7,
                 inode: 21,
                 mtime: "2026-07-13T12:01:00"
               }
             }

      assert second.relative_path == "Season 1/Frieren - 02.MP4"
      refute Map.has_key?(first, :path)
      refute Jason.encode!(inventory) =~ release
    end

    test "normalizes a single-file download to its basename" do
      source = "/downloads/Frieren - 01.mkv"

      stub_virtual_tree(
        %{
          "/" => dir_stat(1),
          "/downloads" => dir_stat(2),
          source => file_stat(21, 10, {{2026, 7, 13}, {12, 1, 0}})
        },
        %{}
      )

      assert {:ok, %{files: [video], folder?: false}} =
               Library.inventory_anime_videos(source)

      assert video.relative_path == "Frieren - 01.mkv"

      assert %{size: 10, major_device: 7, inode: 21, mtime: "2026-07-13T12:01:00"} =
               video.identity
    end

    test "retains PathPolicy rejection for symlink and out-of-root sources" do
      symlink = "/downloads/escaped.mkv"

      stub_virtual_tree(
        %{
          "/" => dir_stat(1),
          "/downloads" => dir_stat(2),
          symlink => %File.Stat{type: :symlink, inode: 30, major_device: 7}
        },
        %{}
      )

      assert {:error, :unsafe_source} = Library.inventory_anime_videos(symlink)
      assert {:error, :unsafe_source} = Library.inventory_anime_videos("/outside/video.mkv")
    end

    defp stub_virtual_tree(stats, listings) do
      stub(Cinder.Library.FilesystemMock, :lstat, fn path -> Map.fetch(stats, path) end)
      stub(Cinder.Library.FilesystemMock, :ls, fn path -> Map.fetch(listings, path) end)
    end

    defp dir_stat(inode),
      do: %File.Stat{type: :directory, inode: inode, major_device: 7}

    defp file_stat(inode, size, mtime),
      do: %File.Stat{
        type: :regular,
        inode: inode,
        major_device: 7,
        size: size,
        mtime: mtime
      }

    defp restore_env(key, nil), do: Application.delete_env(:cinder, key)
    defp restore_env(key, value), do: Application.put_env(:cinder, key, value)
  end

  describe "stage_anime_episodes/2" do
    setup do
      saved_path_policy = Application.get_env(:cinder, :path_policy)
      saved_import_roots = Application.get_env(:cinder, :import_roots)

      Application.put_env(:cinder, :path_policy, Cinder.Test.PermissivePathPolicy)
      Application.put_env(:cinder, :import_roots, ["/downloads"])

      on_exit(fn ->
        restore_env(:path_policy, saved_path_policy)
        restore_env(:import_roots, saved_import_roots)
      end)

      :ok
    end

    test "one source covering two episodes in one season creates one canonical stage" do
      fixture = anime_fixture("many-to-many-mapping")
      grab = anime_grab(fixture)
      stub_anime_filesystem(fixture)

      assert {:ok, staged} = Library.stage_anime_episodes(grab, anime_preflight(fixture))

      expected = Enum.map(fixture["expected"]["destinations"], &Path.join(@tv_lib, &1))

      assert staged |> Enum.map(fn {_episode_id, stage} -> stage.dest end) |> Enum.uniq() ==
               expected

      assert length(staged) == 2
      assert length(Library.stage_ids(Enum.map(staged, &elem(&1, 1)))) == 1
      assert Repo.aggregate(ImportStage, :count) == 1
    end

    test "an anime upgrade keeps a better held file" do
      fixture = anime_fixture("many-to-many-mapping")
      held = fixture["expected"]["destinations"] |> hd() |> then(&Path.join(@tv_lib, &1))
      grab = anime_grab(fixture)

      episodes =
        Enum.map(grab.episodes, fn episode ->
          %{
            episode
            | file_path: held,
              imported_resolution: "1080p",
              imported_source: "BLURAY",
              imported_size: 9 * @gb
          }
        end)

      grab = %{
        grab
        | episodes: episodes,
          arbitrate_at_import: true,
          release_title: "Frieren.720p.WEBDL"
      }

      virtual = stub_anime_filesystem(fixture)

      Agent.update(virtual, fn state ->
        stat = %File.Stat{type: :regular, size: 9 * @gb, inode: 999, major_device: 1}
        %{state | files: Map.put(state.files, held, stat)}
      end)

      assert {:ok, staged} = Library.stage_anime_episodes(grab, anime_preflight(fixture))
      assert Enum.all?(staged, fn {_episode_id, stage} -> stage.dest == held end)
      assert Enum.all?(staged, fn {_episode_id, stage} -> stage.placed? == false end)
      assert Enum.all?(staged, fn {_episode_id, stage} -> stage.quality.resolution == "1080p" end)
    end

    test "an anime upgrade ignores filename language after policy verification" do
      fixture = anime_fixture("many-to-many-mapping")
      held = fixture["expected"]["destinations"] |> hd() |> then(&Path.join(@tv_lib, &1))
      grab = anime_grab(fixture)

      episodes =
        Enum.map(grab.episodes, fn episode ->
          series = %{episode.season.series | original_language: "ja"}

          %{
            episode
            | season: %{episode.season | series: series},
              file_path: held,
              imported_resolution: "720p",
              imported_source: "WEBDL",
              imported_language: "JAPANESE",
              imported_size: 1 * @gb
          }
        end)

      grab = %{
        grab
        | episodes: episodes,
          arbitrate_at_import: true,
          release_title: "Frieren.1080p.BLURAY"
      }

      virtual = stub_anime_filesystem(fixture)

      Agent.update(virtual, fn state ->
        stat = %File.Stat{type: :regular, size: 1 * @gb, inode: 999, major_device: 1}
        %{state | files: Map.put(state.files, held, stat)}
      end)

      assert {:ok, staged} = Library.stage_anime_episodes(grab, anime_preflight(fixture))
      assert Enum.all?(staged, fn {_episode_id, stage} -> stage.quality.resolution == "1080p" end)
    end

    test "a shared story source is policy-probed once and its report supplies stage metadata" do
      fixture = anime_fixture("many-to-many-mapping")
      source = Path.join(fixture["absolute_download_root"], "Frieren - 12.mkv")
      grab = %{anime_grab(fixture) | release_policy_snapshot: release_policy_snapshot()}
      enable_media_info()
      stub_anime_filesystem(fixture)

      expect(Cinder.Library.MediaInfoMock, :probe_policy, fn ^source ->
        {:ok, policy_report()}
      end)

      assert {:ok, staged} = Library.stage_anime_episodes(grab, anime_preflight(fixture))
      assert length(staged) == 2

      assert Enum.all?(staged, fn {_episode_id, stage} ->
               stage.quality.audio_languages == ["ja", "fr"] and
                 stage.quality.embedded_subtitles == ["fr"]
             end)
    end

    test "a second story-source mismatch creates no stage or filesystem write" do
      fixture = anime_fixture("multi-file-batch") |> normalize_fixture_mtimes()
      [first, second] = fixture["expected"]["assignments"] |> Map.keys() |> Enum.sort()
      root = fixture["absolute_download_root"]
      first_source = Path.join(root, first)
      second_source = Path.join(root, second)
      grab = %{anime_grab(fixture) | release_policy_snapshot: release_policy_snapshot()}
      preflight = anime_preflight(fixture)

      preflight = %{
        preflight
        | assignments: Enum.sort_by(preflight.assignments, & &1.relative_path)
      }

      enable_media_info()
      stub_anime_inventory(fixture)

      expect(Cinder.Library.MediaInfoMock, :probe_policy, 2, fn
        ^first_source ->
          {:ok, policy_report()}

        ^second_source ->
          {:ok, policy_report(audio: ["ja"])}
      end)

      assert {:error, {:release_policy_mismatch, %{source: ^second, missing_audio: ["fr"]}}} =
               Library.stage_anime_episodes(grab, preflight)

      assert Repo.aggregate(ImportStage, :count) == 0
    end

    test "an unavailable story-source policy probe creates no stage or filesystem write" do
      fixture = anime_fixture("many-to-many-mapping")
      source = Path.join(fixture["absolute_download_root"], "Frieren - 12.mkv")
      grab = %{anime_grab(fixture) | release_policy_snapshot: release_policy_snapshot()}
      enable_media_info()
      stub_anime_inventory(fixture)

      expect(Cinder.Library.MediaInfoMock, :probe_policy, fn ^source -> {:error, :timeout} end)

      assert {:error,
              {:release_policy_unavailable, {:probe_failed, "Frieren - 12.mkv", :timeout}}} =
               Library.stage_anime_episodes(grab, anime_preflight(fixture))

      assert Repo.aggregate(ImportStage, :count) == 0
    end

    test "positively ignored extras are never policy-probed" do
      fixture = anime_fixture("positive-extras") |> normalize_fixture_mtimes()
      story = Path.join(fixture["absolute_download_root"], "Frieren - 1.mkv")
      grab = %{anime_grab(fixture) | release_policy_snapshot: release_policy_snapshot()}
      enable_media_info()
      stub_anime_filesystem(fixture)

      expect(Cinder.Library.MediaInfoMock, :probe_policy, fn ^story ->
        {:ok, policy_report()}
      end)

      assert {:ok, [{101, stage}]} =
               Library.stage_anime_episodes(grab, anime_preflight(fixture))

      assert stage.quality.audio_languages == ["ja", "fr"]
      assert Repo.aggregate(ImportStage, :count) == 1
    end

    test "one source crossing seasons creates one canonical destination per season" do
      fixture = anime_fixture("cross-season-output")
      grab = anime_grab(fixture)
      stub_anime_filesystem(fixture)

      assert {:ok, staged} = Library.stage_anime_episodes(grab, anime_preflight(fixture))

      expected =
        fixture["expected"]["destinations"] |> Enum.map(&Path.join(@tv_lib, &1)) |> Enum.sort()

      assert staged
             |> Enum.map(fn {_episode_id, stage} -> stage.dest end)
             |> Enum.uniq()
             |> Enum.sort() == expected

      series_root = Path.join(@tv_lib, "Frieren (2023) {tmdb-209867}")
      [season_one_episode, season_two_episode] = grab.episodes

      assert staged
             |> Enum.map(fn {episode_id, stage} -> {episode_id, Path.dirname(stage.dest)} end)
             |> Map.new() == %{
               season_one_episode.id => Path.join(series_root, "Season 01"),
               season_two_episode.id => Path.join(series_root, "Season 02")
             }

      assert Repo.aggregate(ImportStage, :count) == 2
    end

    test "a second-season staging failure rolls the first season back" do
      fixture = anime_fixture("cross-season-output")
      grab = anime_grab(fixture)
      virtual = stub_anime_filesystem(fixture, fail_on: "Season 02")

      capture_log(fn ->
        assert {:error, :eacces} =
                 Library.stage_anime_episodes(grab, anime_preflight(fixture))
      end)

      expected = Enum.map(fixture["expected"]["destinations"], &Path.join(@tv_lib, &1))
      files = Agent.get(virtual, & &1.files)
      assert Enum.all?(expected, &(not Map.has_key?(files, &1)))

      assert [%ImportStage{dest: remaining}] = ImportStage.list()
      assert remaining == Enum.find(expected, &String.contains?(&1, "Season 02"))
    end

    test "any persisted file identity mutation restarts preflight before creating a stage" do
      fixture = anime_fixture("inventory-mutation")
      grab = anime_grab(fixture)
      [before] = fixture["before_inventory"]

      mutations = [
        [Map.put(before, "size", 1027)],
        [Map.put(before, "major_device", 2)],
        [Map.put(before, "inode", 127)],
        fixture["after_inventory"]
      ]

      for current <- mutations do
        virtual = stub_anime_filesystem(fixture, inventory: current)

        assert {:restart_preflight, :inventory_changed} =
                 Library.stage_anime_episodes(
                   grab,
                   anime_preflight(fixture, fixture["before_inventory"])
                 )

        assert Repo.aggregate(ImportStage, :count) == 0
        assert Agent.get(virtual, & &1.links) == []
      end
    end

    test "a container disappearing after inventory validation restarts preflight" do
      fixture = anime_fixture("cross-season-output")
      grab = anime_grab(fixture)
      virtual = stub_anime_filesystem(fixture)
      {:ok, dir_calls} = Agent.start_link(fn -> [true, false] end)
      {:ok, policy_calls} = Agent.start_link(fn -> 0 end)
      root = fixture["absolute_download_root"]

      Application.put_env(:cinder, :path_policy, DisappearingPathPolicy)
      Application.put_env(:cinder, :disappearing_path_policy_calls, policy_calls)
      on_exit(fn -> Application.delete_env(:cinder, :disappearing_path_policy_calls) end)

      stub(Cinder.Library.FilesystemMock, :dir?, fn ^root -> next_call(dir_calls, false) end)

      assert {:restart_preflight, :inventory_changed} =
               Library.stage_anime_episodes(grab, anime_preflight(fixture))

      assert Repo.aggregate(ImportStage, :count) == 0
      assert Agent.get(virtual, & &1.links) == []
    end

    test "rejects assignments outside the grab's authoritative episode set" do
      fixture = anime_fixture("many-to-many-mapping")
      grab = anime_grab(fixture)
      stub_anime_filesystem(fixture)

      preflight = %{
        anime_preflight(fixture)
        | assignments: [%{relative_path: "Frieren - 12.mkv", episode_ids: [999]}]
      }

      assert {:error, :invalid_anime_assignment} =
               Library.stage_anime_episodes(grab, preflight)

      assert Repo.aggregate(ImportStage, :count) == 0
    end
  end

  describe "stage_movie/2 frozen release policy" do
    setup do
      enable_media_info()
      :ok
    end

    test "a passing detailed probe is reused for movie stage metadata" do
      source = "/downloads/Anime.Movie.mkv"

      dest =
        "#{@lib}/Anime Movie (2026) {tmdb-42}/Anime Movie (2026) {tmdb-42}.mkv"

      stat = %File.Stat{type: :regular, size: 4 * @gb, inode: 7, major_device: 1}
      movie = policy_movie(source)

      expect(Cinder.Library.FilesystemMock, :dir?, fn ^source -> false end)

      expect(Cinder.Library.MediaInfoMock, :probe_policy, fn ^source ->
        {:ok, policy_report()}
      end)

      stub(Cinder.Library.FilesystemMock, :lstat, fn
        ^source -> {:ok, stat}
        ^dest -> {:error, :enoent}
        _candidate -> {:ok, stat}
      end)

      expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _directory -> :ok end)
      expect(Cinder.Library.FilesystemMock, :ln, 2, fn _source, _destination -> :ok end)
      expect(Cinder.Library.FilesystemMock, :rm, fn _candidate -> :ok end)

      assert {:ok, %{quality: quality}} = Library.stage_movie(movie)
      assert quality.audio_languages == ["ja", "fr"]
      assert quality.embedded_subtitles == ["fr"]
      assert Repo.aggregate(ImportStage, :count) == 1
    end

    test "a confirmed mismatch returns evidence without any staging side effect" do
      source = "/downloads/Anime.Movie.mkv"
      movie = policy_movie(source)

      expect(Cinder.Library.FilesystemMock, :dir?, fn ^source -> false end)

      expect(Cinder.Library.MediaInfoMock, :probe_policy, fn ^source ->
        {:ok, policy_report(audio: ["ja"])}
      end)

      assert {:error,
              {:release_policy_mismatch, %{source: "Anime.Movie.mkv", missing_audio: ["fr"]}}} =
               Library.stage_movie(movie)

      assert Repo.aggregate(ImportStage, :count) == 0
    end

    test "an unavailable probe returns its reason without any staging side effect" do
      source = "/downloads/Anime.Movie.mkv"
      movie = policy_movie(source)

      expect(Cinder.Library.FilesystemMock, :dir?, fn ^source -> false end)
      expect(Cinder.Library.MediaInfoMock, :probe_policy, fn ^source -> {:error, :timeout} end)

      assert {:error, {:release_policy_unavailable, {:probe_failed, "Anime.Movie.mkv", :timeout}}} =
               Library.stage_movie(movie)

      assert Repo.aggregate(ImportStage, :count) == 0
    end
  end

  test "single-file source: hardlinks to Title (Year) {tmdb-N}/… and scans" do
    movie = %Movie{
      title: "Inception",
      year: 2010,
      tmdb_id: 27_205,
      file_path: "/dl/Inception.2010.1080p.mkv"
    }

    Cinder.LibraryStubs.stub_import_ok(5 * @gb)

    assert {:ok, %{dest: dest, quality: quality} = stage} = Library.stage_movie(movie)
    assert dest == "#{@lib}/Inception (2010) {tmdb-27205}/Inception (2010) {tmdb-27205}.mkv"
    assert %{resolution: "1080p", size: 5_000_000_000, language: nil} = quality
    assert :ok = commit!(stage)
  end

  test "an explicit Anime movie profile stages under the Anime movie destination" do
    anime_root = Path.join(@lib, "anime")
    saved = Application.get_env(:cinder, :movies_anime_library_path)
    Application.put_env(:cinder, :movies_anime_library_path, anime_root)
    on_exit(fn -> restore_env(:movies_anime_library_path, saved) end)

    movie = %Movie{
      title: "Your Name",
      year: 2016,
      tmdb_id: 372_058,
      media_profile: :anime,
      file_path: "/dl/Your.Name.2016.1080p.mkv"
    }

    Cinder.LibraryStubs.stub_import_ok(5 * @gb)

    assert {:ok, %{dest: dest}} = Library.stage_movie(movie)
    assert String.starts_with?(dest, anime_root <> "/")
  end

  test "a named movie profile stages inside its arbitrary configured root" do
    root = "/tmp/cinder-family-library"

    assert {:ok, profile} =
             Catalog.create_profile(%{
               name: "Family library",
               kind: :movies,
               handling: :standard,
               library_path: root
             })

    movie = %Movie{
      title: "Paddington",
      year: 2014,
      tmdb_id: 116_149,
      profile_id: profile.id,
      media_profile: :standard,
      file_path: "/dl/Paddington.2014.1080p.mkv"
    }

    Cinder.LibraryStubs.stub_import_ok(5 * @gb)

    assert {:ok, %{dest: dest}} = Library.stage_movie(movie)
    assert String.starts_with?(dest, root <> "/")
  end

  test "single-file import with media_info off returns empty capture lists" do
    # media_info is nil (config/test.exs default) and the download is a single file, so the probe is
    # skipped and no sidecar scan runs — all three capture lists come back empty, never nil.
    movie = %Movie{
      title: "Solo",
      year: 2018,
      tmdb_id: 348_350,
      file_path: "/dl/Solo.2018.1080p.mkv"
    }

    Cinder.LibraryStubs.stub_import_ok(4 * @gb)

    assert {:ok, %{quality: q} = stage} = Library.stage_movie(movie)
    assert q.audio_languages == []
    assert q.embedded_subtitles == []
    assert q.sidecar_subtitles == []
    assert :ok = commit!(stage)
  end

  test "import captures the parsed source into the returned quality" do
    movie = %Movie{
      title: "Inception",
      year: 2010,
      tmdb_id: 27_205,
      file_path: "/dl/Inception.2010.1080p.BluRay.x264-GRP.mkv"
    }

    dest = "#{@lib}/Inception (2010) {tmdb-27205}/Inception (2010) {tmdb-27205}.mkv"

    Cinder.LibraryStubs.stub_import_ok(8 * @gb)

    assert {:ok,
            %{dest: ^dest, quality: %{resolution: "1080p", source: "bluray", language: nil}} =
              stage} = Library.stage_movie(movie)

    assert :ok = commit!(stage)
  end

  test "folder source: picks the largest video file and skips the sample" do
    movie = %Movie{title: "Dune", year: 2021, tmdb_id: 438_631, file_path: "/dl/Dune.2021"}
    dest = "#{@lib}/Dune (2021) {tmdb-438631}/Dune (2021) {tmdb-438631}.mkv"

    # Probed both during staging (resolve_source) and again at commit (the sidecar scan
    # re-checks the source dir) — an exact count isn't the point of this test, so stub rather
    # than pin it.
    stub(Cinder.Library.FilesystemMock, :dir?, fn "/dl/Dune.2021" -> true end)

    stub(Cinder.Library.FilesystemMock, :find_files, fn "/dl/Dune.2021" ->
      {:ok,
       [
         {"/dl/Dune.2021/sample.mkv", 50_000_000},
         {"/dl/Dune.2021/Dune.2021.1080p.mkv", 9_000_000_000},
         {"/dl/Dune.2021/readme.nfo", 2_000}
       ]}
    end)

    stub(Cinder.Library.FilesystemMock, :lstat, fn
      "/dl/Dune.2021/Dune.2021.1080p.mkv" ->
        {:ok, %File.Stat{size: 9_000_000_000, inode: 2}}

      path ->
        if String.contains?(path, ".cinder-stage-"),
          do: {:ok, %File.Stat{size: 9_000_000_000, inode: 3, major_device: 1}},
          else: {:error, :enoent}
    end)

    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> :ok end)
    stub(Cinder.Library.FilesystemMock, :rm, fn _path -> :ok end)
    stub(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)

    assert {:ok, %{dest: ^dest} = stage} = Library.stage_movie(movie)
    assert :ok = commit!(stage)
  end

  test "folder source imports a strict contiguous movie stack and tracks every part" do
    movie = %Movie{title: "Epic", year: 1960, tmdb_id: 1, file_path: "/dl/Epic"}
    cd1 = "/dl/Epic/Epic.CD1.mkv"
    cd2 = "/dl/Epic/Epic.CD2.mkv"

    stub(Cinder.Library.FilesystemMock, :dir?, fn _path -> true end)

    stub(Cinder.Library.FilesystemMock, :find_files, fn "/dl/Epic" ->
      {:ok, [{cd2, 4_000}, {cd1, 3_000}]}
    end)

    stub(Cinder.Library.FilesystemMock, :lstat, fn path ->
      cond do
        path == cd1 ->
          {:ok, %File.Stat{size: 3_000, inode: 11, major_device: 1}}

        path == cd2 ->
          {:ok, %File.Stat{size: 4_000, inode: 12, major_device: 1}}

        String.contains?(path, ".cinder-stage-") ->
          size = if String.contains?(path, "-cd1"), do: 3_000, else: 4_000
          {:ok, %File.Stat{size: size, inode: 20 + size, major_device: 1}}

        true ->
          {:error, :enoent}
      end
    end)

    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _path -> :ok end)
    stub(Cinder.Library.FilesystemMock, :ln, fn _source, _dest -> :ok end)
    stub(Cinder.Library.FilesystemMock, :rename, fn _source, _dest -> :ok end)
    stub(Cinder.Library.FilesystemMock, :rm, fn _path -> :ok end)
    stub(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

    assert {:ok, stage} = Library.stage_movie(movie)
    assert stage.dest =~ "Epic (1960) {tmdb-1}-cd1.mkv"
    assert [part] = stage.part_file_paths
    assert part =~ "Epic (1960) {tmdb-1}-cd2.mkv"
    assert stage.quality.size == 7_000
    assert length(Library.stage_ids([stage])) == 2
    assert :ok = commit!(stage)
  end

  test "a partial or mixed movie stack fails closed" do
    movie = %Movie{title: "Epic", year: 1960, tmdb_id: 1, file_path: "/dl/Epic"}

    expect(Cinder.Library.FilesystemMock, :dir?, fn _path -> true end)

    expect(Cinder.Library.FilesystemMock, :find_files, fn _path ->
      {:ok,
       [
         {"/dl/Epic/Epic.CD1.mkv", 3_000},
         {"/dl/Epic/Epic.CD3.mkv", 4_000}
       ]}
    end)

    assert {:error, :ambiguous_multipart_movie} = Library.stage_movie(movie)
  end

  describe "scan/1" do
    test "returns the configured media server result" do
      expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)
      expect(Cinder.Library.MediaServerMock, :scan, fn :tv -> {:error, :unavailable} end)

      assert :ok = Library.scan(:movies)
      assert {:error, :unavailable} = Library.scan(:tv)
    end
  end

  test "scan failure is best-effort: import still succeeds once the file is linked" do
    movie = %Movie{title: "Heat", year: 1995, tmdb_id: 9799, file_path: "/dl/Heat.mkv"}
    dest = "#{@lib}/Heat (1995) {tmdb-9799}/Heat (1995) {tmdb-9799}.mkv"

    Cinder.LibraryStubs.stub_import_ok(1)
    stub(Cinder.Library.MediaServerMock, :scan, fn _kind -> {:error, :econnrefused} end)

    assert {:ok, %{dest: ^dest} = stage} = Library.stage_movie(movie)

    log = capture_log(fn -> assert :ok = commit!(stage) end)
    assert log =~ "media-server scan failed"
  end

  test "a scan that RAISES is best-effort: import still succeeds once the file is linked" do
    movie = %Movie{title: "Heat", year: 1995, tmdb_id: 9799, file_path: "/dl/Heat.mkv"}
    dest = "#{@lib}/Heat (1995) {tmdb-9799}/Heat (1995) {tmdb-9799}.mkv"

    Cinder.LibraryStubs.stub_import_ok(1)
    # A misconfigured media-server impl can raise (e.g. a malformed base URL or a
    # network error deep in the HTTP stack) — that must not crash an already-
    # hardlinked import.
    stub(Cinder.Library.MediaServerMock, :scan, fn _kind -> raise "boom" end)

    assert {:ok, %{dest: ^dest} = stage} = Library.stage_movie(movie)

    log = capture_log(fn -> assert :ok = commit!(stage) end)
    assert log =~ "media-server scan failed"
  end

  test "RAR-packed movie fails explicitly instead of pretending no media exists" do
    movie = %Movie{title: "X", year: 2000, file_path: "/dl/X"}

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)

    expect(Cinder.Library.FilesystemMock, :find_files, fn _ ->
      {:ok, [{"/dl/X/sample.mkv", 500}, {"/dl/X/b.rar", 9_999}]}
    end)

    # No mkdir_p / ln / scan expected — verify_on_exit! fails if any is called.
    assert {:error, :unsupported_archive} = Library.stage_movie(movie)
  end

  test "disc structures fail explicitly without an extractor/playback contract" do
    movie = %Movie{title: "X", year: 2000, file_path: "/dl/X"}

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)

    expect(Cinder.Library.FilesystemMock, :find_files, fn _ ->
      {:ok,
       [
         {"/dl/X/BDMV/STREAM/00001.m2ts", 9_999},
         {"/dl/X/BDMV/STREAM/sample.ts", 500}
       ]}
    end)

    assert {:error, :unsupported_disc} = Library.stage_movie(movie)
  end

  test "a direct ISO fails explicitly before source validation" do
    movie = %Movie{title: "X", year: 2000, file_path: "/dl/X.iso"}

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)

    assert {:error, :unsupported_disc} = Library.stage_movie(movie)
  end

  test "folder with no media container returns no_video_file" do
    movie = %Movie{title: "X", year: 2000, file_path: "/dl/X"}

    expect(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)
    expect(Cinder.Library.FilesystemMock, :find_files, fn _ -> {:ok, [{"/dl/X/a.nfo", 10}]} end)

    assert {:error, :no_video_file} = Library.stage_movie(movie)
  end

  test "nil file_path → {:error, :no_file_path}, no FS calls" do
    assert {:error, :no_file_path} =
             Library.stage_movie(%Movie{title: "X", year: 2000, file_path: nil})
  end

  test "sanitizes filesystem-illegal characters in the title" do
    movie = %Movie{title: "Face/Off", year: 1997, tmdb_id: 9615, file_path: "/dl/FaceOff.mkv"}
    dest = "#{@lib}/FaceOff (1997) {tmdb-9615}/FaceOff (1997) {tmdb-9615}.mkv"

    Cinder.LibraryStubs.stub_import_ok(1)

    assert {:ok, %{dest: ^dest} = stage} = Library.stage_movie(movie)
    assert :ok = commit!(stage)
  end

  test "year: nil falls back to a bare Title {tmdb-N} (no empty parens)" do
    movie = %Movie{title: "Untitled", year: nil, tmdb_id: 12_345, file_path: "/dl/x.mkv"}
    dest = "#{@lib}/Untitled {tmdb-12345}/Untitled {tmdb-12345}.mkv"

    Cinder.LibraryStubs.stub_import_ok(1)

    assert {:ok, %{dest: ^dest} = stage} = Library.stage_movie(movie)
    assert :ok = commit!(stage)
  end

  test "a title that sanitizes to empty falls back to a tmdb-based folder" do
    movie = %Movie{title: "???", year: 2010, tmdb_id: 555, file_path: "/dl/x.mkv"}
    dest = "#{@lib}/tmdb-555/tmdb-555.mkv"

    Cinder.LibraryStubs.stub_import_ok(1)

    assert {:ok, %{dest: ^dest} = stage} = Library.stage_movie(movie)
    assert :ok = commit!(stage)
  end

  test "a whitespace-only title also falls back to a tmdb-based folder" do
    movie = %Movie{title: "   ", year: 2010, tmdb_id: 777, file_path: "/dl/x.mkv"}
    dest = "#{@lib}/tmdb-777/tmdb-777.mkv"

    Cinder.LibraryStubs.stub_import_ok(1)

    assert {:ok, %{dest: ^dest} = stage} = Library.stage_movie(movie)
    assert :ok = commit!(stage)
  end

  test "a dots-only title (path-traversal attempt) falls back to a tmdb-based folder" do
    # ".." would otherwise Path.join to escape the library root; route it to the tmdb fallback.
    movie = %Movie{title: "..", year: 2010, tmdb_id: 888, file_path: "/dl/x.mkv"}
    dest = "#{@lib}/tmdb-888/tmdb-888.mkv"

    Cinder.LibraryStubs.stub_import_ok(1)

    assert {:ok, %{dest: ^dest} = stage} = Library.stage_movie(movie)
    assert :ok = commit!(stage)
  end

  test "TV: import_episodes takes the identical :exdev → copy path and imports the episode" do
    Cinder.LibraryStubs.stub_import_exdev(3 * @gb)

    assert {:ok, [{7, dest, _q}], []} =
             Library.import_episodes("/dl/Show.S01E03.1080p.mkv", [ep(7, 3)])

    assert dest == "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E03.mkv"
  end

  test "TV: an explicit Anime series stages under the Anime TV destination" do
    anime_root = Path.join(@tv_lib, "anime")
    saved = Application.get_env(:cinder, :tv_anime_library_path)
    Application.put_env(:cinder, :tv_anime_library_path, anime_root)
    on_exit(fn -> restore_env(:tv_anime_library_path, saved) end)
    Cinder.LibraryStubs.stub_import_ok(3 * @gb)

    assert {:ok, [{7, stage}], []} =
             Library.stage_episodes("/dl/Show.S01E03.1080p.mkv", [
               ep(7, 3, 1, media_profile: :anime)
             ])

    assert String.starts_with?(stage.dest, anime_root <> "/")
  end

  test "TV: a residual part stays beside its primary file after a profile change" do
    anime_root = Path.join(@tv_lib, "anime")
    saved = Application.get_env(:cinder, :tv_anime_library_path)
    Application.put_env(:cinder, :tv_anime_library_path, anime_root)
    on_exit(fn -> restore_env(:tv_anime_library_path, saved) end)

    source = "/dl/Show.extra.mkv"
    primary = "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E03.mkv"
    episode = %{ep(7, 3, 1, media_profile: :anime) | file_path: primary}
    grab = %Grab{content_path: source}
    file = %GrabFile{id: 11, relative_path: Path.basename(source), size: @gb, device: 1, inode: 1}

    Cinder.LibraryStubs.stub_import_ok(@gb)

    assert {:ok, %{dest: dest}} = Library.stage_grab_file_part(grab, file, episode)
    assert String.starts_with?(dest, @tv_lib <> "/")
    refute String.starts_with?(dest, anime_root <> "/")
  end

  describe "import_episodes/2" do
    # FS/media mocks stubbed (multiple, order-independent calls); assertions read the return value.
    defp stub_dir(files) do
      stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)
      stub(Cinder.Library.FilesystemMock, :find_files, fn _ -> {:ok, files} end)
    end

    defp stub_link_ok do
      stub(Cinder.Library.FilesystemMock, :lstat, fn _ ->
        {:ok, %File.Stat{size: @gb, inode: 1}}
      end)

      stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
      stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> :ok end)
      stub(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)
    end

    test "single episode matched by SxxEyy → Show (Year) {tmdb-N}/Season NN/Show (Year) {tmdb-N} - SxxEyy.ext" do
      stub_dir([{"/dl/Show.S01E03.1080p.mkv", 9 * @gb}, {"/dl/sample.mkv", 50_000_000}])
      stub_link_ok()

      log =
        capture_log(fn ->
          assert {:ok, [{7, dest, _quality}], ["/dl/sample.mkv"]} =
                   Library.import_episodes("/dl", [ep(7, 3)])

          assert dest ==
                   "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E03.mkv"
        end)

      assert log =~ "import skipped 1 unmatched file(s): [\"/dl/sample.mkv\"]"
    end

    test "a Standard S00Exx file imports into the Season 00/ layout (Sonarr parity)" do
      stub_dir([{"/dl/Show.S00E05.1080p.mkv", 9 * @gb}])
      stub_link_ok()

      assert {:ok, [{7, dest, _quality}], []} =
               Library.import_episodes("/dl", [ep(7, 5, 0)])

      assert dest ==
               "#{@tv_lib}/Show (2008) {tmdb-1}/Season 00/Show (2008) {tmdb-1} - S00E05.mkv"
    end

    test "a deobfuscated SABnzbd .cinder-<uuid> suffix still maps to the correct episode (issue #127)" do
      # PR #124 renames the SABnzbd job (and the deobfuscated video) to
      # "<title>.cinder-<uuid>"; the trailing UUID must not stop the SxxEyy match.
      stub_dir([
        {"/dl/Show.S01E05.1080p.WEB.h264.cinder-a1b2c3d4-e5f6-47a8-89b0-c1d2e3f4a5b6.mkv",
         9 * @gb}
      ])

      stub_link_ok()

      assert {:ok, [{9, dest, _quality}], []} = Library.import_episodes("/dl", [ep(9, 5)])

      assert dest ==
               "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E05.mkv"
    end

    test "season pack: each file maps to its own episode and dest" do
      stub_dir([{"/dl/Show.S01E01.mkv", 3 * @gb}, {"/dl/Show.S01E02.mkv", 3 * @gb}])
      stub_link_ok()

      assert {:ok, imported, []} = Library.import_episodes("/dl", [ep(1, 1), ep(2, 2)])

      assert Enum.map(Enum.sort_by(imported, &elem(&1, 0)), fn {id, dest, _q} -> {id, dest} end) ==
               [
                 {1,
                  "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E01.mkv"},
                 {2,
                  "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E02.mkv"}
               ]
    end

    test "a double-episode file links once at a range-named path shared by both episodes" do
      source = "/dl/Show.S01E01E02.1080p.mkv"

      dest =
        "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E01-E02.mkv"

      stub_dir([{source, 4 * @gb}])
      parent = self()

      stub(Cinder.Library.FilesystemMock, :lstat, fn _ ->
        {:ok, %File.Stat{size: @gb, inode: 1}}
      end)

      stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)

      stub(Cinder.Library.FilesystemMock, :ln, fn path, target ->
        send(parent, {:linked, path, target})
        :ok
      end)

      stub(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)

      assert {:ok, imported, []} = Library.import_episodes("/dl", [ep(1, 1), ep(2, 2)])

      assert Enum.map(Enum.sort_by(imported, &elem(&1, 0)), fn {id, dest, _q} -> {id, dest} end) ==
               [
                 {1, dest},
                 {2, dest}
               ]

      assert_received {:linked, ^source, ^dest}
      refute_received {:linked, _, _}
    end

    test "a non-contiguous multi-episode file keeps its distinct episode tokens" do
      source = "/dl/Show.S01E01E03.1080p.mkv"

      stub_dir([{source, 4 * @gb}])
      stub_link_ok()

      assert {:ok, imported, []} = Library.import_episodes("/dl", [ep(1, 1), ep(3, 3)])

      assert Enum.map(Enum.sort_by(imported, &elem(&1, 0)), fn {id, dest, _q} -> {id, dest} end) ==
               [
                 {1,
                  "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E01E03.mkv"},
                 {3,
                  "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E01E03.mkv"}
               ]
    end

    test "two files parsing the same episode: largest imports, the rest log as unmatched" do
      # Both parse S01E01; only one source can own the episode's dest — keep the largest, route
      # the loser to unmatched (logged) rather than colliding two sources onto one dest.
      stub_dir([{"/dl/Show.S01E01.mkv", 3 * @gb}, {"/dl/Show.S01E01.REPACK.mkv", 5 * @gb}])
      stub_link_ok()

      log =
        capture_log(fn ->
          assert {:ok, [{1, dest, _q}], ["/dl/Show.S01E01.mkv"]} =
                   Library.import_episodes("/dl", [ep(1, 1)])

          assert dest ==
                   "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E01.mkv"
        end)

      assert log =~ "unmatched"
    end

    test "an unmatchable file is logged and skipped; the rest still import" do
      stub_dir([{"/dl/Show.S01E01.mkv", 3 * @gb}, {"/dl/Show.S01E05.mkv", 3 * @gb}])
      stub_link_ok()

      log =
        capture_log(fn ->
          assert {:ok, [{1, dest, _q}], ["/dl/Show.S01E05.mkv"]} =
                   Library.import_episodes("/dl", [ep(1, 1)])

          assert dest ==
                   "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E01.mkv"
        end)

      assert log =~ "unmatched"
    end

    test "single-file content_path with no SxxEyy → largest-wins for a lone-episode grab" do
      # Not a directory: the lone file is the source; the grab names the episode.
      stub(Cinder.Library.FilesystemMock, :dir?, fn "/dl/random.mkv" -> false end)
      stub_link_ok()

      assert {:ok, [{1, dest, _q}], []} = Library.import_episodes("/dl/random.mkv", [ep(1, 4)])
      assert dest == "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E04.mkv"
    end

    test "video+sample with no SxxEyy: largest-wins assigns the episode, skips the sample" do
      stub_dir([{"/dl/show.finale.mkv", 9 * @gb}, {"/dl/sample.mkv", 50_000_000}])
      stub_link_ok()

      log =
        capture_log(fn ->
          assert {:ok, [{1, dest, _q}], ["/dl/sample.mkv"]} =
                   Library.import_episodes("/dl", [ep(1, 3)])

          assert dest ==
                   "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E03.mkv"
        end)

      assert log =~ "import skipped 1 unmatched file(s): [\"/dl/sample.mkv\"]"
    end

    test "lone-episode grab does NOT fall back when a file names a different specific episode" do
      # Show.S01E04 clearly names E04; the grab wants E03 — never mislabel E04 as E03.
      stub_dir([{"/dl/Show.S01E04.mkv", 3 * @gb}])

      log =
        capture_log(fn ->
          assert {:ok, [], ["/dl/Show.S01E04.mkv"]} =
                   Library.import_episodes("/dl", [ep(1, 3)])
        end)

      assert log =~ "import skipped 1 unmatched file(s): [\"/dl/Show.S01E04.mkv\"]"
    end

    test "no video file → {:ok, [], []} and no scan" do
      stub_dir([{"/dl/readme.nfo", 10}])

      assert {:ok, [], []} = Library.import_episodes("/dl", [ep(1, 1)])
    end

    test "ln :eexist is treated as success when dest is the same file (idempotent re-import)" do
      stub_dir([{"/dl/Show.S01E01.mkv", 3 * @gb}])
      stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
      stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> {:error, :eexist} end)
      # Same inode for source + dest → already our hardlink → idempotent.
      stub(Cinder.Library.FilesystemMock, :lstat, fn _ ->
        {:ok, %File.Stat{size: @gb, inode: 7}}
      end)

      stub(Cinder.Library.MediaServerMock, :scan, fn _kind -> :ok end)

      assert {:ok, [{1, _dest, _q}], []} = Library.import_episodes("/dl", [ep(1, 1)])
    end

    test "a transient hardlink error returns {:error, reason} so the grab retries" do
      stub_dir([{"/dl/Show.S01E01.mkv", 3 * @gb}])

      stub(Cinder.Library.FilesystemMock, :lstat, fn _ ->
        {:ok, %File.Stat{size: @gb, inode: 1}}
      end)

      stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
      stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> {:error, :eacces} end)

      assert {:error, :eacces} = Library.import_episodes("/dl", [ep(1, 1)])
    end

    test "nil content_path → {:error, :no_content_path}" do
      assert {:error, :no_content_path} = Library.import_episodes(nil, [ep(1, 1)])
    end

    test "a vanished content_path folder surfaces {:error, reason}, not an empty import" do
      # dir? is false for a nonexistent path too (unmounted volume): without the lstat guard
      # the folder name would pass as a "lone file", filter to no videos, and park+blocklist.
      stub(Cinder.Library.FilesystemMock, :dir?, fn "/dl/gone" -> false end)
      expect(Cinder.Library.FilesystemMock, :lstat, fn "/dl/gone" -> {:error, :enoent} end)

      assert {:error, :enoent} = Library.import_episodes("/dl/gone", [ep(1, 1)])
    end

    test "TV re-import replaces an episode's file on a resolution upgrade" do
      series = struct(%Series{title: "Show", year: 2008, tmdb_id: 1}, [])

      ep = %Episode{
        id: 5,
        episode_number: 1,
        imported_resolution: "720p",
        imported_size: 1 * @gb,
        imported_language: nil,
        season: %Season{season_number: 1, series: series}
      }

      source = "/dl/Show.S01E01.1080p.mkv"
      dest = "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E01.mkv"

      expect(Cinder.Library.FilesystemMock, :dir?, fn "/dl/grab" -> true end)

      # sweep_temps' walk checks the dest dir is a directory before listing it.
      expect(Cinder.Library.FilesystemMock, :dir?, fn _dir -> true end)

      # The sidecar scan after a placed file re-checks the source dir; fall through to "not a dir".
      stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)

      expect(Cinder.Library.FilesystemMock, :find_files, fn "/dl/grab" ->
        {:ok, [{source, 3 * @gb}]}
      end)

      expect(Cinder.Library.FilesystemMock, :lstat, fn ^source ->
        {:ok, %File.Stat{size: 3 * @gb, inode: 7}}
      end)

      expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
      expect(Cinder.Library.FilesystemMock, :ln, fn ^source, ^dest -> {:error, :eexist} end)
      expect(Cinder.Library.FilesystemMock, :lstat, fn ^dest -> {:ok, %File.Stat{inode: 99}} end)
      # sweep_temps
      expect(Cinder.Library.FilesystemMock, :find_files, fn _dir -> {:ok, []} end)

      expect(Cinder.Library.FilesystemMock, :ln, fn ^source, tmp ->
        assert String.contains?(tmp, ".cinder-tmp-")
        :ok
      end)

      expect(Cinder.Library.FilesystemMock, :rename, fn _tmp, ^dest -> :ok end)
      expect(Cinder.Library.MediaServerMock, :scan, fn _ -> :ok end)

      assert {:ok, [{5, ^dest, %{resolution: "1080p", size: 3_000_000_000, language: nil}}], []} =
               Library.import_episodes("/dl/grab", [ep])
    end

    test "TV re-import keeps the existing episode file when the new release is not an upgrade" do
      series = struct(%Series{title: "Show", year: 2008, tmdb_id: 1}, [])

      ep = %Episode{
        id: 6,
        episode_number: 1,
        imported_resolution: "1080p",
        imported_size: 9 * @gb,
        imported_language: nil,
        season: %Season{season_number: 1, series: series}
      }

      source = "/dl/Show.S01E01.720p.mkv"
      dest = "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E01.mkv"

      expect(Cinder.Library.FilesystemMock, :dir?, fn "/dl/grab" -> true end)

      expect(Cinder.Library.FilesystemMock, :find_files, fn "/dl/grab" ->
        {:ok, [{source, 1 * @gb}]}
      end)

      expect(Cinder.Library.FilesystemMock, :lstat, fn ^source ->
        {:ok, %File.Stat{size: 1 * @gb, inode: 7}}
      end)

      expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
      expect(Cinder.Library.FilesystemMock, :ln, fn ^source, ^dest -> {:error, :eexist} end)
      expect(Cinder.Library.FilesystemMock, :lstat, fn ^dest -> {:ok, %File.Stat{inode: 99}} end)
      expect(Cinder.Library.MediaServerMock, :scan, fn _ -> :ok end)

      log =
        capture_log(fn ->
          assert {:ok, [{6, ^dest, %{resolution: "1080p", size: 9_000_000_000, language: nil}}],
                  []} =
                   Library.import_episodes("/dl/grab", [ep])
        end)

      assert log =~ "kept existing"
    end
  end

  describe "delete_file/1" do
    test "nil/blank path is a no-op (no filesystem calls)" do
      assert :ok = Cinder.Library.delete_file(nil)
      assert :ok = Cinder.Library.delete_file("")
    end

    test "unlinks the file and prunes the now-empty movie folder, stopping at the root" do
      path = "#{@lib}/Inception (2010)/Inception (2010).mkv"
      expect(Cinder.Library.FilesystemMock, :rm, fn ^path -> :ok end)
      # parent "Inception (2010)" is empty -> removed; its parent is the root -> never attempted.
      expect(Cinder.Library.FilesystemMock, :rmdir, fn "#{@lib}/Inception (2010)" -> :ok end)

      assert :ok = Cinder.Library.delete_file(path)
    end

    test "prunes Season + show folders for an episode, stopping at the tv root" do
      path = "#{@tv_lib}/Show (2010)/Season 01/Show (2010) - S01E01.mkv"
      expect(Cinder.Library.FilesystemMock, :rm, fn ^path -> :ok end)

      expect(Cinder.Library.FilesystemMock, :rmdir, fn "#{@tv_lib}/Show (2010)/Season 01" ->
        :ok
      end)

      expect(Cinder.Library.FilesystemMock, :rmdir, fn "#{@tv_lib}/Show (2010)" -> :ok end)

      assert :ok = Cinder.Library.delete_file(path)
    end

    test "deletes and prunes safely inside an Anime destination" do
      anime_root = Path.join(@tv_lib, "anime")
      saved = Application.get_env(:cinder, :tv_anime_library_path)
      Application.put_env(:cinder, :tv_anime_library_path, anime_root)
      on_exit(fn -> restore_env(:tv_anime_library_path, saved) end)

      path = "#{anime_root}/Show (2010)/Season 01/Show (2010) - S01E01.mkv"
      season = "#{anime_root}/Show (2010)/Season 01"
      show = "#{anime_root}/Show (2010)"
      expect(Cinder.Library.FilesystemMock, :rm, fn ^path -> :ok end)
      expect(Cinder.Library.FilesystemMock, :rmdir, fn ^season -> :ok end)
      expect(Cinder.Library.FilesystemMock, :rmdir, fn ^show -> :ok end)

      assert :ok = Cinder.Library.delete_file(path)
    end

    test "stops pruning at the first non-empty parent" do
      path = "#{@lib}/Inception (2010)/Inception (2010).mkv"
      expect(Cinder.Library.FilesystemMock, :rm, fn ^path -> :ok end)
      expect(Cinder.Library.FilesystemMock, :rmdir, fn _ -> {:error, :enotempty} end)

      assert :ok = Cinder.Library.delete_file(path)
    end

    test "a missing file is idempotent (:ok) and still prunes" do
      path = "#{@lib}/Gone (2000)/Gone (2000).mkv"
      expect(Cinder.Library.FilesystemMock, :rm, fn ^path -> {:error, :enoent} end)
      expect(Cinder.Library.FilesystemMock, :rmdir, fn _ -> {:error, :enoent} end)

      assert :ok = Cinder.Library.delete_file(path)
    end

    test "a real unlink error is surfaced and nothing is pruned" do
      path = "#{@lib}/Locked (2000)/Locked (2000).mkv"
      expect(Cinder.Library.FilesystemMock, :rm, fn ^path -> {:error, :eacces} end)
      # no rmdir expectation -> verify_on_exit! fails if pruning is attempted.

      assert {:error, :eacces} = Cinder.Library.delete_file(path)
    end
  end

  describe "delete_download_source/1 (issue #115)" do
    setup do
      saved_explicit_roots = Application.get_env(:cinder, :explicit_import_roots)
      Application.put_env(:cinder, :explicit_import_roots, ["/downloads"])

      on_exit(fn -> restore_env(:explicit_import_roots, saved_explicit_roots) end)

      :ok
    end

    test "nil/blank path is a no-op (no filesystem calls)" do
      assert :ok = Cinder.Library.delete_download_source(nil)
      assert :ok = Cinder.Library.delete_download_source("")
    end

    test "deletes the whole per-operation directory via rm_rf" do
      path = "/downloads/cinder-abc123"
      expect(Cinder.Library.FilesystemMock, :rm_rf, fn ^path -> {:ok, [path]} end)

      assert :ok = Cinder.Library.delete_download_source(path)
    end

    test "deletes a lone file when there's no wrapper directory" do
      path = "/downloads/movie.mkv"
      expect(Cinder.Library.FilesystemMock, :rm_rf, fn ^path -> {:ok, [path]} end)

      assert :ok = Cinder.Library.delete_download_source(path)
    end

    test "a missing/already-gone path is idempotent (:ok)" do
      path = "/downloads/cinder-gone"
      expect(Cinder.Library.FilesystemMock, :rm_rf, fn ^path -> {:ok, []} end)

      assert :ok = Cinder.Library.delete_download_source(path)
    end

    test "a real rm_rf error is surfaced" do
      path = "/downloads/cinder-locked"
      expect(Cinder.Library.FilesystemMock, :rm_rf, fn ^path -> {:error, :eacces, path} end)

      assert {:error, :eacces} = Cinder.Library.delete_download_source(path)
    end

    test "with only inferred/absent import roots, deletion refuses (no rm_rf)" do
      Application.delete_env(:cinder, :explicit_import_roots)

      assert {:error, :import_roots_not_explicit} =
               Cinder.Library.delete_download_source("/downloads/cinder-abc123")
    end
  end

  describe "delete_download_source/1 through the real PathPolicy (issue #119 review)" do
    setup do
      saved_path_policy = Application.get_env(:cinder, :path_policy)
      saved_explicit_roots = Application.get_env(:cinder, :explicit_import_roots)

      Application.put_env(:cinder, :path_policy, Cinder.Library.PathPolicy)
      Application.put_env(:cinder, :explicit_import_roots, ["/downloads"])

      on_exit(fn ->
        restore_env(:path_policy, saved_path_policy)
        restore_env(:explicit_import_roots, saved_explicit_roots)
      end)

      :ok
    end

    test "an in-root source directory deletes" do
      path = "/downloads/cinder-abc123"

      stub(Cinder.Library.FilesystemMock, :lstat, fn
        ^path -> {:ok, %File.Stat{type: :directory}}
        _ancestor -> {:ok, %File.Stat{type: :directory}}
      end)

      expect(Cinder.Library.FilesystemMock, :rm_rf, fn ^path -> {:ok, [path]} end)

      assert :ok = Cinder.Library.delete_download_source(path)
    end

    test "a path outside the configured root refuses (no rm_rf)" do
      assert {:error, :unsafe_delete} =
               Cinder.Library.delete_download_source("/etc/cinder-outside")
    end

    test "the import root itself refuses (no rm_rf)" do
      stub(Cinder.Library.FilesystemMock, :lstat, fn _path ->
        {:ok, %File.Stat{type: :directory}}
      end)

      assert {:error, :unsafe_delete} = Cinder.Library.delete_download_source("/downloads")
    end
  end

  defp anime_fixture(id), do: Enum.find(@anime_cases, &(&1["id"] == id))

  defp normalize_fixture_mtimes(fixture) do
    mtime = "2026-07-13T12:00:00"

    fixture =
      update_in(fixture["inventory"], &Enum.map(&1, fn file -> Map.put(file, "mtime", mtime) end))

    update_in(fixture["expected"]["decisions"]["files"], fn files ->
      Enum.map(files, &Map.put(&1, "mtime", mtime))
    end)
  end

  defp anime_grab(fixture) do
    series = %Series{title: "Frieren", year: 2023, tmdb_id: 209_867}

    episodes =
      Enum.map(fixture["episodes"], fn episode ->
        %Episode{
          id: episode["id"],
          episode_number: episode["episode_number"],
          season: %Season{
            season_number: episode["season_number"],
            series: series
          }
        }
      end)

    %Grab{content_path: fixture["absolute_download_root"], episodes: episodes}
  end

  defp anime_preflight(fixture, inventory \\ nil) do
    inventory = inventory || fixture["inventory"]
    decision_files = fixture["expected"]["decisions"]["files"]

    decisions =
      Map.put(
        fixture["expected"]["decisions"],
        "files",
        Enum.map(inventory, fn identity ->
          decision =
            Enum.find(decision_files, %{}, &(&1["relative_path"] == identity["relative_path"]))

          Map.merge(decision, identity)
        end)
      )

    assignments =
      Enum.map(fixture["expected"]["assignments"] || fixture["before_assignments"], fn
        {relative_path, episode_ids} ->
          %{relative_path: relative_path, episode_ids: episode_ids}
      end)

    %{assignments: assignments, decisions: decisions, folder?: true}
  end

  defp stub_anime_filesystem(fixture, opts \\ []) do
    inventory = Keyword.get(opts, :inventory, fixture["inventory"])
    root = fixture["absolute_download_root"]
    fail_on = Keyword.get(opts, :fail_on)

    files =
      Map.new(inventory, fn entry ->
        {Path.join(root, entry["relative_path"]), anime_file_stat(entry)}
      end)

    {:ok, virtual} = Agent.start_link(fn -> %{files: files, links: []} end)

    stub(Cinder.Library.FilesystemMock, :dir?, &(&1 == root))

    stub(Cinder.Library.FilesystemMock, :find_files, fn ^root ->
      {:ok,
       Enum.map(inventory, fn entry ->
         {Path.join(root, entry["relative_path"]), entry["size"]}
       end)}
    end)

    stub(Cinder.Library.FilesystemMock, :lstat, fn path ->
      virtual_lstat(virtual, path)
    end)

    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _path -> :ok end)

    stub(Cinder.Library.FilesystemMock, :ln, fn source, target ->
      anime_link(virtual, source, target, fail_on)
    end)

    stub(Cinder.Library.FilesystemMock, :rm, fn path ->
      Agent.update(virtual, fn state -> %{state | files: Map.delete(state.files, path)} end)
      :ok
    end)

    stub(Cinder.Library.FilesystemMock, :rmdir, fn _path -> {:error, :enotempty} end)
    stub(Cinder.Library.FilesystemMock, :rename, fn _source, _target -> :ok end)

    virtual
  end

  defp stub_anime_inventory(fixture) do
    inventory = fixture["inventory"]
    root = fixture["absolute_download_root"]
    files = Map.new(inventory, &{Path.join(root, &1["relative_path"]), anime_file_stat(&1)})

    stub(Cinder.Library.FilesystemMock, :dir?, &(&1 == root))

    stub(Cinder.Library.FilesystemMock, :find_files, fn ^root ->
      {:ok, Enum.map(inventory, &{Path.join(root, &1["relative_path"]), &1["size"]})}
    end)

    stub(Cinder.Library.FilesystemMock, :lstat, &Map.fetch(files, &1))
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

  defp policy_movie(source) do
    %Movie{
      title: "Anime Movie",
      year: 2026,
      tmdb_id: 42,
      file_path: source,
      preferred_language: "french",
      original_language: "ja",
      release_policy_snapshot: release_policy_snapshot()
    }
  end

  defp release_policy_snapshot do
    %{
      "version" => 1,
      "required_audio_languages" => ["ja", "fr"],
      "required_embedded_subtitle_languages" => ["fr"],
      "release_group" => "subsplease",
      "release_title" => "Anime.Release"
    }
  end

  defp policy_report(overrides \\ []) do
    Map.merge(
      %{
        audio: ["ja", "fr"],
        subtitles: ["fr"],
        audio_unknown?: false,
        subtitle_unknown?: false
      },
      Map.new(overrides)
    )
  end

  defp anime_file_stat(entry) do
    %File.Stat{
      type: :regular,
      size: entry["size"],
      major_device: entry["major_device"],
      inode: entry["inode"],
      mtime: entry["mtime"] |> NaiveDateTime.from_iso8601!() |> NaiveDateTime.to_erl()
    }
  end

  defp anime_link(virtual, source, target, fail_on) do
    if stage_failure?(target, fail_on),
      do: {:error, :eacces},
      else: link_virtual_file(virtual, source, target)
  end

  defp stage_failure?(target, fail_on) when is_binary(fail_on),
    do:
      String.contains?(target, fail_on) &&
        String.contains?(Path.basename(target), ".cinder-stage-")

  defp stage_failure?(_target, _fail_on), do: false

  defp virtual_lstat(virtual, path) do
    case Agent.get(virtual, fn state -> Map.fetch(state.files, path) end) do
      {:ok, stat} -> {:ok, stat}
      :error -> {:error, :enoent}
    end
  end

  defp link_virtual_file(virtual, source, target) do
    Agent.get_and_update(virtual, fn state ->
      case Map.fetch(state.files, source) do
        {:ok, stat} ->
          {:ok,
           %{
             state
             | files: Map.put(state.files, target, stat),
               links: [{source, target} | state.links]
           }}

        :error ->
          {{:error, :enoent}, state}
      end
    end)
  end

  defp next_call(agent, default) do
    Agent.get_and_update(agent, fn
      [value | rest] -> {value, rest}
      [] -> {default, []}
    end)
  end
end
