defmodule Cinder.LibrarySourceUpgradeTest do
  # async: false — sets :cinder source-preference env to exercise the source axis end to end.
  use Cinder.DataCase, async: false

  import Mox

  alias Cinder.Catalog.{Episode, Season, Series}
  alias Cinder.Library
  alias Cinder.Library.StagedImport

  setup :verify_on_exit!

  @gb 1_000_000_000

  @tv_lib "/tmp/cinder-test-tv-library"

  setup do
    stub(Cinder.Library.FilesystemMock, :chmod, fn _path, _mode -> :ok end)

    prev_tv = Application.get_env(:cinder, :tv_preferred_sources)
    Application.put_env(:cinder, :tv_preferred_sources, ["bluray", "webdl"])

    on_exit(fn ->
      case prev_tv do
        nil -> Application.delete_env(:cinder, :tv_preferred_sources)
        v -> Application.put_env(:cinder, :tv_preferred_sources, v)
      end
    end)

    :ok
  end

  test "same-resolution better source replaces an episode's file" do
    series = struct(%Series{title: "Show", year: 2008, tmdb_id: 1}, [])

    ep = %Episode{
      id: 5,
      episode_number: 1,
      imported_resolution: "1080p",
      imported_size: 9 * @gb,
      imported_language: nil,
      imported_source: "webdl",
      season: %Season{season_number: 1, series: series}
    }

    source = "/dl/grab/Show.S01E01.1080p.BluRay.x264.mkv"
    dest = "#{@tv_lib}/Show (2008) {tmdb-1}/Season 01/Show (2008) {tmdb-1} - S01E01.mkv"

    stub(Cinder.Library.FilesystemMock, :dir?, fn path -> path == "/dl/grab" end)

    stub(Cinder.Library.FilesystemMock, :find_files, fn "/dl/grab" ->
      {:ok, [{source, 2 * @gb}]}
    end)

    # The download (inode 7) and the held webdl file at dest (inode 99) are different files.
    stub(Cinder.Library.FilesystemMock, :lstat, fn
      ^source ->
        {:ok, %File.Stat{type: :regular, size: 2 * @gb, inode: 7, major_device: 1}}

      ^dest ->
        {:ok, %File.Stat{type: :regular, size: 9 * @gb, inode: 99, major_device: 1}}

      path ->
        if Cinder.LibraryStubs.candidate_path?(path),
          do: {:ok, %File.Stat{type: :regular, size: 2 * @gb, inode: 50, major_device: 1}},
          else: {:error, :enoent}
    end)

    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :ln, fn _src, _dest -> :ok end)
    stub(Cinder.Library.FilesystemMock, :rm, fn _path -> :ok end)
    # The held file moves aside to its backup before the candidate lands at dest.
    expect(Cinder.Library.FilesystemMock, :rename, fn ^dest, _backup -> :ok end)

    assert {:ok, staged, []} = Library.stage_episodes("/dl/grab", [ep])

    assert [{5, ^dest, %{resolution: "1080p", source: "bluray"}, true}] =
             StagedImport.record(staged)
  end
end
