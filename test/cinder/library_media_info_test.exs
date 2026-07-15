defmodule Cinder.LibraryMediaInfoTest do
  # async: false — toggles the optional :media_info impl via Application env for this module only.
  use ExUnit.Case, async: false

  import Mox
  import ExUnit.CaptureLog

  alias Cinder.Acquisition.Language
  alias Cinder.Catalog.{Episode, Movie, Season, Series}
  alias Cinder.Library

  @tv_lib "/tmp/cinder-test-tv-library"

  @lib "/tmp/cinder-test-library"
  @source "/dl/movie.mkv"
  @dest "#{@lib}/Movie (2024) {tmdb-42}/Movie (2024) {tmdb-42}.mkv"

  setup :verify_on_exit!

  setup do
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

  defp expect_single_file_import do
    expect(Cinder.Library.FilesystemMock, :dir?, fn @source -> false end)

    expect(Cinder.Library.FilesystemMock, :lstat, fn @source ->
      {:ok, %File.Stat{size: 1, inode: 1}}
    end)

    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    expect(Cinder.Library.FilesystemMock, :ln, fn @source, @dest -> :ok end)
    expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)
  end

  test "imports when the file's audio includes the wanted language (639-2 code match)" do
    expect(Cinder.Library.FilesystemMock, :dir?, fn @source -> false end)

    # stub, not expect: capture_media/1 probes again after verify_audio, so probe runs twice.
    stub(Cinder.Library.MediaInfoMock, :probe, fn @source ->
      {:ok, %{audio: ["fra", "eng"], subtitles: []}}
    end)

    expect(Cinder.Library.FilesystemMock, :lstat, fn @source ->
      {:ok, %File.Stat{size: 1, inode: 1}}
    end)

    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    expect(Cinder.Library.FilesystemMock, :ln, fn @source, @dest -> :ok end)
    expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

    assert {:ok, @dest, _quality} = Library.import_movie(french_movie())
  end

  test "parks a confirmed wrong-language file without importing it" do
    expect(Cinder.Library.FilesystemMock, :dir?, fn @source -> false end)

    expect(Cinder.Library.MediaInfoMock, :probe, fn @source ->
      {:ok, %{audio: ["hun"], subtitles: []}}
    end)

    # No mkdir_p/ln/scan — the import short-circuits before touching the filesystem.

    assert {:error, :wrong_audio_language} = Library.import_movie(french_movie())
  end

  test "imports when the probe reports no usable language (can't verify, don't over-park)" do
    expect(Cinder.Library.FilesystemMock, :dir?, fn @source -> false end)

    stub(Cinder.Library.MediaInfoMock, :probe, fn @source ->
      {:ok, %{audio: [], subtitles: []}}
    end)

    expect_single_file_import_tail()

    assert {:ok, @dest, _quality} = Library.import_movie(french_movie())
  end

  test "imports when the probe errors (e.g. ffprobe not installed)" do
    expect(Cinder.Library.FilesystemMock, :dir?, fn @source -> false end)
    stub(Cinder.Library.MediaInfoMock, :probe, fn @source -> {:error, :enoent} end)
    expect_single_file_import_tail()

    log =
      capture_log(fn -> assert {:ok, @dest, _quality} = Library.import_movie(french_movie()) end)

    assert log =~ "media-info audio check skipped for /dl/movie.mkv: :enoent"
    assert log =~ "media-info probe failed for /dl/movie.mkv: {:error, :enoent}"
  end

  test "an 'any' pick still captures via probe but never parks (no wanted language to verify)" do
    # capture_media/1 probes on every import; with no wanted language verify_audio adds no park.
    stub(Cinder.Library.MediaInfoMock, :probe, fn @source ->
      {:ok, %{audio: ["eng"], subtitles: []}}
    end)

    expect_single_file_import()

    assert {:ok, @dest, _quality} =
             Library.import_movie(%{french_movie() | preferred_language: "any"})
  end

  test "imports for a language outside the registry (can't verify → don't false-park)" do
    # Croatian original_language ("hr") isn't in the registry, so the wanted set is unknown — the
    # correctly-Croatian file must import, not park.
    movie = %{french_movie() | original_language: "hr"}
    expect(Cinder.Library.FilesystemMock, :dir?, fn @source -> false end)

    stub(Cinder.Library.MediaInfoMock, :probe, fn @source ->
      {:ok, %{audio: ["hrv"], subtitles: []}}
    end)

    expect_single_file_import_tail()

    assert {:ok, @dest, _quality} = Library.import_movie(movie)
  end

  test "a 639-2 variant code (Norwegian 'nob') is accepted, not false-parked" do
    movie = %{french_movie() | original_language: "no"}
    expect(Cinder.Library.FilesystemMock, :dir?, fn @source -> false end)

    stub(Cinder.Library.MediaInfoMock, :probe, fn @source ->
      {:ok, %{audio: ["nob"], subtitles: []}}
    end)

    expect_single_file_import_tail()

    assert {:ok, @dest, _quality} = Library.import_movie(movie)
  end

  test "an unrecognised audio code can't confirm a mismatch → imports" do
    # Norwegian wanted, file tagged with a code we don't list → conservative: don't park.
    movie = %{french_movie() | original_language: "no"}
    expect(Cinder.Library.FilesystemMock, :dir?, fn @source -> false end)

    stub(Cinder.Library.MediaInfoMock, :probe, fn @source ->
      {:ok, %{audio: ["zzz"], subtitles: []}}
    end)

    expect_single_file_import_tail()

    assert {:ok, @dest, _quality} = Library.import_movie(movie)
  end

  @gb 1_000_000_000

  test "import_movie captures audio + embedded + sidecar languages into the returned quality" do
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
      {:ok, %{audio: ["eng", "fre"], subtitles: ["eng"]}}
    end)

    stub(Cinder.Library.FilesystemMock, :lstat, fn
      ^source -> {:ok, %File.Stat{size: 5 * @gb, inode: 1}}
      ^sidecar_dest -> {:error, :enoent}
    end)

    stub(Cinder.Library.FilesystemMock, :moviehash_data, fn ^dest -> :too_small end)

    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)

    # Both the video and the sidecar hardlink go through ln; capture them to prove the sidecar linked.
    stub(Cinder.Library.FilesystemMock, :ln, fn s, d ->
      send(parent, {:ln, s, d})
      :ok
    end)

    stub(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)

    assert {:ok, ^dest, q} = Library.import_movie(movie)
    assert q.audio_languages == ["eng", "fre"]
    assert q.embedded_subtitles == ["eng"]
    assert q.sidecar_subtitles == ["fr"]

    assert_received {:ln, ^source, ^dest}
    assert_received {:ln, ^srt, ^sidecar_dest}
    await_subtitle_tasks()
  end

  # The tail of a single-file import after resolve_source's dir? (which the probe tests set
  # themselves so the probe expectation lands between dir? and mkdir_p).
  defp expect_single_file_import_tail do
    expect(Cinder.Library.FilesystemMock, :lstat, fn @source ->
      {:ok, %File.Stat{size: 1, inode: 1}}
    end)

    expect(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    expect(Cinder.Library.FilesystemMock, :ln, fn @source, @dest -> :ok end)
    expect(Cinder.Library.MediaServerMock, :scan, fn :movies -> :ok end)
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
