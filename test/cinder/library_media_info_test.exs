defmodule Cinder.LibraryMediaInfoTest do
  # async: false — toggles the optional :media_info impl via Application env for this module only.
  # DataCase (not bare ExUnit.Case): stage_movie now writes an ImportStage journal row.
  use Cinder.DataCase, async: false

  import Mox
  import ExUnit.CaptureLog

  alias Cinder.Acquisition.Language
  alias Cinder.Catalog.{Episode, Movie, Season, Series}
  alias Cinder.Library
  alias Cinder.Library.ImportStage

  @tv_lib "/tmp/cinder-test-tv-library"

  @lib "/tmp/cinder-test-library"
  @source "/dl/movie.mkv"
  @dest "#{@lib}/Movie (2024) {tmdb-42}/Movie (2024) {tmdb-42}.mkv"

  setup :verify_on_exit!

  setup do
    stub(Cinder.Library.FilesystemMock, :chmod, fn _path, _mode -> :ok end)

    # Enable the optional audio probe for this module (disabled by default in config/test.exs).
    Application.put_env(:cinder, :media_info, Cinder.Library.MediaInfoMock)
    on_exit(fn -> Application.delete_env(:cinder, :media_info) end)
    :ok
  end

  # A French movie ('original' → wants French audio) downloaded as a single file.
  defp french_movie do
    %Movie{
      title: "Movie",
      year: 2024,
      tmdb_id: 42,
      file_path: @source,
      preferred_language: "original",
      original_language: "fr"
    }
  end

  test "stream status distinguishes a match, known absence, and incomplete evidence" do
    assert Language.stream_status("fr", ["fra"], false) == :satisfied
    assert Language.stream_status("fr", ["eng"], false) == :mismatch
    assert Language.stream_status("fr", ["eng"], true) == :unknown
    assert Language.stream_status("fr", ["zzz"], false) == :unknown
  end

  defp commit!(stage) do
    ImportStage.mark_committed!(Library.stage_ids([stage]))
    Library.commit_stage(stage)
  end

  test "imports when the file's audio includes the wanted language (639-2 code match)" do
    # stub, not expect: capture_media/1 probes again after verify_audio, so probe runs twice.
    stub(Cinder.Library.MediaInfoMock, :probe, fn @source ->
      {:ok, %{audio: ["fra", "eng"], subtitles: []}}
    end)

    Cinder.LibraryStubs.stub_import_ok(1)

    assert {:ok, %{dest: @dest}} = Library.stage_movie(french_movie())
  end

  test "parks a confirmed wrong-language file without importing it" do
    expect(Cinder.Library.FilesystemMock, :dir?, fn @source -> false end)

    expect(Cinder.Library.MediaInfoMock, :probe, fn @source ->
      {:ok, %{audio: ["hun"], subtitles: []}}
    end)

    # No lstat/mkdir_p/ln/scan — the stage short-circuits before touching the filesystem further.

    assert {:error, :wrong_audio_language} = Library.stage_movie(french_movie())
  end

  test "imports when the probe reports no usable language (can't verify, don't over-park)" do
    stub(Cinder.Library.MediaInfoMock, :probe, fn @source ->
      {:ok, %{audio: [], subtitles: []}}
    end)

    Cinder.LibraryStubs.stub_import_ok(1)

    assert {:ok, %{dest: @dest}} = Library.stage_movie(french_movie())
  end

  test "imports when the probe errors (e.g. ffprobe not installed)" do
    stub(Cinder.Library.MediaInfoMock, :probe, fn @source -> {:error, :enoent} end)
    Cinder.LibraryStubs.stub_import_ok(1)

    log =
      capture_log(fn ->
        assert {:ok, %{dest: @dest}} = Library.stage_movie(french_movie())
      end)

    assert log =~ "media-info audio check skipped for /dl/movie.mkv: :enoent"
    assert log =~ "media-info probe failed for /dl/movie.mkv: {:error, :enoent}"
  end

  test "an 'any' pick still captures via probe but never parks (no wanted language to verify)" do
    # capture_media/1 probes on every import; with no wanted language verify_audio adds no park.
    stub(Cinder.Library.MediaInfoMock, :probe, fn @source ->
      {:ok, %{audio: ["eng"], subtitles: []}}
    end)

    Cinder.LibraryStubs.stub_import_ok(1)

    assert {:ok, %{dest: @dest}} =
             Library.stage_movie(%{french_movie() | preferred_language: "any"})
  end

  test "imports for a language outside the registry (can't verify → don't false-park)" do
    # Croatian original_language ("hr") isn't in the registry, so the wanted set is unknown — the
    # correctly-Croatian file must import, not park.
    movie = %{french_movie() | original_language: "hr"}

    stub(Cinder.Library.MediaInfoMock, :probe, fn @source ->
      {:ok, %{audio: ["hrv"], subtitles: []}}
    end)

    Cinder.LibraryStubs.stub_import_ok(1)

    assert {:ok, %{dest: @dest}} = Library.stage_movie(movie)
  end

  test "a 639-2 variant code (Norwegian 'nob') is accepted, not false-parked" do
    movie = %{french_movie() | original_language: "no"}

    stub(Cinder.Library.MediaInfoMock, :probe, fn @source ->
      {:ok, %{audio: ["nob"], subtitles: []}}
    end)

    Cinder.LibraryStubs.stub_import_ok(1)

    assert {:ok, %{dest: @dest}} = Library.stage_movie(movie)
  end

  test "an unrecognised audio code can't confirm a mismatch → imports" do
    # Norwegian wanted, file tagged with a code we don't list → conservative: don't park.
    movie = %{french_movie() | original_language: "no"}

    stub(Cinder.Library.MediaInfoMock, :probe, fn @source ->
      {:ok, %{audio: ["zzz"], subtitles: []}}
    end)

    Cinder.LibraryStubs.stub_import_ok(1)

    assert {:ok, %{dest: @dest}} = Library.stage_movie(movie)
  end

  # A release can spell the right title and hold another film. Only a clearly SHORTER file is
  # evidence of that (15% AND 10 minutes): an extended cut, PAL speed-up, or a short film a few
  # minutes off must still import, and a file the probe can't time can't be judged at all.
  test "rejects a movie file far shorter than its TMDB runtime, and nothing else" do
    Cinder.LibraryStubs.stub_import_ok(1)
    movie = %{french_movie() | preferred_language: "any"}

    cases = [
      {121, 98, :reject},
      {121, 102, :reject},
      {121, 104, :import},
      {121, 116, :import},
      {121, 160, :import},
      {50, 42, :import},
      {121, nil, :import},
      {nil, 98, :import}
    ]

    for {tmdb, file, expected} <- cases do
      duration = file && file * 60.0

      stub(Cinder.Library.MediaInfoMock, :probe, fn @source ->
        {:ok, %{audio: [], subtitles: [], duration: duration}}
      end)

      result = Library.stage_movie(%{movie | runtime: tmdb})

      case expected do
        :reject ->
          assert {:error,
                  {:release_policy_mismatch,
                   %{tmdb_runtime_minutes: ^tmdb, file_runtime_minutes: ^file}}} = result,
                 "#{file} min for a #{tmdb} min movie should be rejected"

        :import ->
          assert {:ok, %{dest: @dest} = stage} = result,
                 "#{inspect(file)} min for a #{inspect(tmdb)} min movie should import"

          Library.rollback_stage(stage)
      end
    end
  end

  # A CD1/CD2 stack is one film between its parts: judged part by part, every stacked movie would
  # look half its length and be rejected.
  test "judges a CD1/CD2 stack on its combined length" do
    movie = %Movie{title: "Epic", year: 1960, tmdb_id: 1, file_path: "/dl/Epic", runtime: 121}
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

    stub(Cinder.Library.MediaInfoMock, :probe, fn
      ^cd1 -> {:ok, %{audio: [], subtitles: [], duration: 60 * 60.0}}
      ^cd2 -> {:ok, %{audio: [], subtitles: [], duration: 61 * 60.0}}
    end)

    assert {:ok, stage} = Library.stage_movie(movie)
    assert [_part] = stage.part_file_paths
    Library.rollback_stage(stage)
  end

  @gb 1_000_000_000

  test "stage_movie captures audio + embedded + sidecar languages into the returned quality" do
    # A *folder* download so the sidecar scan runs (sidecars ship inside a release folder).
    parent = self()
    folder = "/dl/M (2020)"
    source = "#{folder}/M.2020.1080p.mkv"
    srt = "#{folder}/M.2020.1080p.fr.srt"
    dest = "#{@lib}/M (2020) {tmdb-99}/M (2020) {tmdb-99}.mkv"
    sidecar_dest = "#{@lib}/M (2020) {tmdb-99}/M (2020) {tmdb-99}.fr.srt"
    Mox.set_mox_global()

    # "any" pick → no wanted language → verify_audio adds no probe; capture_media does the one probe.
    movie = %Movie{
      title: "M",
      year: 2020,
      tmdb_id: 99,
      file_path: folder,
      preferred_language: "any"
    }

    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)

    stub(Cinder.Library.FilesystemMock, :find_files, fn ^folder ->
      {:ok, [{source, 5 * @gb}, {srt, 40_000}]}
    end)

    stub(Cinder.Library.MediaInfoMock, :probe, fn ^source ->
      {:ok, %{audio: ["eng", "fre"], subtitles: ["eng"], default_audio: "fre"}}
    end)

    stub(Cinder.Library.FilesystemMock, :lstat, fn
      ^source ->
        {:ok, %File.Stat{size: 5 * @gb, inode: 1}}

      ^sidecar_dest ->
        {:error, :enoent}

      ^dest ->
        {:error, :enoent}

      path ->
        if String.contains?(path, ".cinder-stage-"),
          do: {:ok, %File.Stat{size: 5 * @gb, inode: 2, major_device: 1}},
          else: {:error, :enoent}
    end)

    stub(Cinder.Library.FilesystemMock, :moviehash_data, fn ^dest -> :too_small end)

    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :rm, fn _path -> :ok end)

    # Both the video and the sidecar hardlink go through ln; capture them to prove the sidecar linked.
    stub(Cinder.Library.FilesystemMock, :ln, fn s, d ->
      send(parent, {:ln, s, d})
      :ok
    end)

    stub(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

    assert {:ok, %{dest: ^dest, quality: q} = stage} = Library.stage_movie(movie)
    assert :ok = commit!(stage)

    assert q.audio_languages == ["eng", "fre"]
    assert q.embedded_subtitles == ["eng"]
    assert q.sidecar_subtitles == ["fr"]

    # Issue #197: the probe -> quality -> column chain. nil renders identically to "no default
    # established", so a value dropped anywhere along here would never fail a UI test.
    assert q.default_audio_language == "fre"

    assert_received {:ln, ^srt, ^sidecar_dest}
    await_subtitle_tasks()
  end

  # A French series ('original') episode with its season/series preloaded (what the TvPoller passes).
  defp french_ep(id, ep_num) do
    series = %Series{
      title: "Show",
      year: 2008,
      tmdb_id: 1,
      original_language: "fr",
      preferred_language: "original"
    }

    %Episode{id: id, episode_number: ep_num, season: %Season{season_number: 1, series: series}}
  end

  test "TV: a wrong-language episode file is dropped to unmatched; the right one imports" do
    files = [
      {"/dl/Show.S01E01.1080p.mkv", 3_000_000_000},
      {"/dl/Show.S01E02.1080p.mkv", 3_000_000_000}
    ]

    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)
    stub(Cinder.Library.FilesystemMock, :find_files, fn _ -> {:ok, files} end)

    stub(Cinder.Library.FilesystemMock, :lstat, fn _ ->
      {:ok, %File.Stat{size: 3_000_000_000, inode: 1}}
    end)

    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> :ok end)
    stub(Cinder.Library.MediaServerMock, :scan, fn :tv -> :ok end)

    # E01 is French audio (kept); E02 is a Hungarian dub (dropped).
    stub(Cinder.Library.MediaInfoMock, :probe, fn
      "/dl/Show.S01E01.1080p.mkv" -> {:ok, %{audio: ["fra"], subtitles: []}}
      "/dl/Show.S01E02.1080p.mkv" -> {:ok, %{audio: ["hun"], subtitles: []}}
    end)

    log =
      capture_log(fn ->
        assert {:ok, [{1, dest, _q}], ["/dl/Show.S01E02.1080p.mkv"]} =
                 Library.import_episodes("/dl", [french_ep(1, 1), french_ep(2, 2)])

        assert dest ==
                 "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E01.mkv"
      end)

    assert log =~
             "import skipped 1 unmatched file(s): [\"/dl/Show.S01E02.1080p.mkv\"]"
  end

  test "TV: an all-wrong-language pack imports nothing (the grab then re-searches)" do
    files = [
      {"/dl/Show.S01E01.1080p.mkv", 3_000_000_000},
      {"/dl/Show.S01E02.1080p.mkv", 3_000_000_000}
    ]

    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)
    stub(Cinder.Library.FilesystemMock, :find_files, fn _ -> {:ok, files} end)

    stub(Cinder.Library.MediaInfoMock, :probe, fn _ -> {:ok, %{audio: ["hun"], subtitles: []}} end)

    log =
      capture_log(fn ->
        assert {:ok, [], unmatched} =
                 Library.import_episodes("/dl", [french_ep(1, 1), french_ep(2, 2)])

        assert Enum.sort(unmatched) ==
                 Enum.sort(["/dl/Show.S01E01.1080p.mkv", "/dl/Show.S01E02.1080p.mkv"])
      end)

    assert log =~ "import skipped 2 unmatched file(s):"
  end

  test "import_episodes captures audio + embedded + sidecar languages per imported episode" do
    parent = self()

    # 'any' pick → no wanted language → reject_wrong_audio adds no probe; capture_media does the one.
    series = %Series{title: "Show", year: 2008, tmdb_id: 1, preferred_language: "any"}

    episode = %Episode{
      id: 7,
      episode_number: 1,
      season: %Season{season_number: 1, series: series}
    }

    source = "/dl/Show.S01E01.1080p.mkv"
    srt = "/dl/Show.S01E01.1080p.fr.srt"
    dest = "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E01.mkv"

    sidecar_dest =
      "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E01.fr.srt"

    Mox.set_mox_global()

    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> true end)

    stub(Cinder.Library.FilesystemMock, :find_files, fn "/dl" ->
      {:ok, [{source, 3 * @gb}, {srt, 40_000}]}
    end)

    stub(Cinder.Library.MediaInfoMock, :probe, fn ^source ->
      {:ok, %{audio: ["eng", "fre"], subtitles: ["eng"]}}
    end)

    stub(Cinder.Library.FilesystemMock, :lstat, fn
      ^source -> {:ok, %File.Stat{size: 3 * @gb, inode: 1}}
      ^sidecar_dest -> {:error, :enoent}
    end)

    stub(Cinder.Library.FilesystemMock, :moviehash_data, fn ^dest -> :too_small end)

    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)

    stub(Cinder.Library.FilesystemMock, :ln, fn s, d ->
      send(parent, {:ln, s, d})
      :ok
    end)

    stub(Cinder.Library.MediaServerMock, :scan, fn :tv -> :ok end)

    assert {:ok, [{7, ^dest, q}], []} = Library.import_episodes("/dl", [episode])
    assert q.audio_languages == ["eng", "fre"]
    assert q.embedded_subtitles == ["eng"]
    assert q.sidecar_subtitles == ["fr"]

    assert_received {:ln, ^source, ^dest}

    assert_received {:ln, ^srt, ^sidecar_dest}
    await_subtitle_tasks()
  end

  # The Fetcher processes casts one at a time in mailbox order, so a synchronous round-trip after
  # dispatch only returns once every previously-enqueued fetch has finished.
  defp await_subtitle_tasks do
    :sys.get_state(Cinder.Subtitles.Fetcher)
  end
end
