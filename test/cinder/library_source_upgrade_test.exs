defmodule Cinder.LibrarySourceUpgradeTest do
  # async: false — sets :cinder source-preference env to exercise the source axis end to end.
  use ExUnit.Case, async: false

  import Mox

  alias Cinder.Catalog.{Episode, Season, Series}
  alias Cinder.Library

  setup :verify_on_exit!

  @gb 1_000_000_000

  @tv_lib "/tmp/cinder-test-tv-library"

  setup do
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

    expect(Cinder.Library.FilesystemMock, :dir?, fn "/dl/grab" -> true end)

    # The sidecar scan after the replaced file re-checks the source dir; fall through to "not a dir".
    stub(Cinder.Library.FilesystemMock, :dir?, fn _ -> false end)

    expect(Cinder.Library.FilesystemMock, :find_files, fn "/dl/grab" ->
      {:ok, [{source, 2 * @gb}]}
    end)

    expect(Cinder.Library.FilesystemMock, :lstat, fn ^source ->
      {:ok, %File.Stat{size: 2 * @gb, inode: 7}}
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

    assert {:ok, [{5, ^dest, %{resolution: "1080p", source: "bluray"}}], []} =
             Library.import_episodes("/dl/grab", [ep])
  end
end
