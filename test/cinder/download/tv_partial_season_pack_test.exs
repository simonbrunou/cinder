defmodule Cinder.Download.TvPartialSeasonPackTest do
  @moduledoc """
  #251: the normal TV sweep searches for *wanted* episodes, so a season pack grabbed for the two
  still-missing episodes of a season also delivers the eight already in the library. Those files
  claim no linked episode and used to become undecided `grab_files` — an operator hold with eight
  clicks, for episodes we already have. We know exactly which episode each of them is, so they are
  dropped instead. Files naming an episode we don't hold, or naming nothing, are still residuals.
  """
  use Cinder.DataCase, async: false

  import Mox
  import Cinder.CatalogFixtures

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Grab, GrabFile, Grabs}
  alias Cinder.Download.TvPoller
  alias Cinder.Repo

  setup :set_mox_global

  @tag :tmp_dir
  test "a pack for a partly-available season closes without residual holds", %{tmp_dir: tmp} do
    %{grab: grab, wanted: wanted, held: held} = partial_season_pack(tmp, [])

    start_supervised!({TvPoller, interval: 60_000})
    assert :ok = TvPoller.poll()

    # The grab closes outright: no residual files, nothing in the admin action badge.
    refute Repo.get(Grab, grab.id)
    assert Repo.all(GrabFile) == []
    assert Catalog.count_operator_holds() == 0

    # The two wanted episodes imported.
    for episode <- wanted do
      reloaded = Repo.get!(Episode, episode.id)
      assert reloaded.file_path
      assert File.exists?(reloaded.file_path)
    end

    # The eight already-available ones kept the files they had, untouched.
    for episode <- held do
      reloaded = Repo.get!(Episode, episode.id)
      assert reloaded.file_path == episode.file_path
      assert File.read!(reloaded.file_path) == "held-#{episode.episode_number}"
    end
  end

  @tag :tmp_dir
  test "a file naming no episode we hold is still an operator decision", %{tmp_dir: tmp} do
    %{grab: grab} = partial_season_pack(tmp, ["Show.S01E99.mkv", "bonus-featurette.mkv"])

    start_supervised!({TvPoller, interval: 60_000})
    assert :ok = TvPoller.poll()

    grab = Repo.get!(Grab, grab.id) |> Repo.preload(:grab_files)

    # Exactly the two unknowable files, not the eight we could identify.
    assert grab.grab_files |> Enum.map(& &1.relative_path) |> Enum.sort() ==
             ["Show.S01E99.mkv", "bonus-featurette.mkv"] |> Enum.sort()

    assert Grabs.grab_hold(grab) == :residual_files
  end

  @tag :tmp_dir
  test "a two-parter spanning a held and a wanted episode stays a decision", %{tmp_dir: tmp} do
    # E08 is in the library, E09 is not. `Show.S01E08E09.mkv` is E09's only candidate file, so
    # dropping it would discard E09's content with the download and burn a bounded re-search.
    %{grab: grab, held: held} = partial_season_pack(tmp, ["Show.S01E08E09.1080p.WEB-DL.mkv"])

    start_supervised!({TvPoller, interval: 60_000})
    assert :ok = TvPoller.poll()

    grab = Repo.get!(Grab, grab.id) |> Repo.preload(:grab_files)

    assert Enum.map(grab.grab_files, & &1.relative_path) == ["Show.S01E08E09.1080p.WEB-DL.mkv"]
    assert Grabs.grab_hold(grab) == :residual_files

    # E08 is untouched either way — the file was never a candidate to replace it.
    e08 = Enum.find(held, &(&1.episode_number == 8))
    assert Repo.get!(Episode, e08.id).file_path == e08.file_path
  end

  # A 10-episode season: E01–E08 already in the library, E09–E10 wanted. The pack ships all ten.
  defp partial_season_pack(tmp, extra_files) do
    %{downloads: downloads, tv: tv} = real_tv_library(tmp)

    release_dir = Path.join(downloads, "Show.S01.1080p.WEB-DL-GRP")
    File.mkdir_p!(release_dir)
    library = Path.join([tv, "Show (2008) {tmdb-7788}", "Season 01"])
    File.mkdir_p!(library)

    for number <- 1..10 do
      File.write!(
        Path.join(release_dir, "Show.S01E#{pad(number)}.1080p.WEB-DL.mkv"),
        "release-#{number}"
      )
    end

    Enum.each(extra_files, &File.write!(Path.join(release_dir, &1), "extra"))

    series = series_fixture(%{tmdb_id: 7788, tvdb_id: 7788, title: "Show", year: 2008})
    season = season_fixture(series)

    held =
      for number <- 1..8 do
        path = Path.join(library, "Show (2008) {tmdb-7788} - S01E#{pad(number)}.mkv")
        File.write!(path, "held-#{number}")

        episode_fixture(season, %{
          episode_number: number,
          file_path: path,
          imported_resolution: "1080p",
          imported_source: "BLURAY",
          imported_size: 9_000_000_000
        })
      end

    wanted = for number <- 9..10, do: episode_fixture(season, %{episode_number: number})

    # The sweep links only the WANTED episodes — that is what makes the other eight unclaimed.
    {:ok, grab} =
      Catalog.create_grab(
        "partial-#{System.unique_integer([:positive])}",
        :usenet,
        Enum.map(wanted, & &1.id),
        "Show.S01.1080p.WEB-DL-GRP"
      )

    {:ok, grab} = Catalog.mark_grab_downloaded(grab, release_dir)

    %{grab: grab, wanted: wanted, held: held}
  end

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")

  defp real_tv_library(tmp) do
    downloads = Path.join(tmp, "downloads")
    tv = Path.join(tmp, "tv")
    File.mkdir_p!(downloads)
    File.mkdir_p!(tv)

    keys = [
      :filesystem,
      :path_policy,
      :import_roots,
      :explicit_import_roots,
      :tv_library_path,
      :move_on_import
    ]

    saved = Map.new(keys, &{&1, Application.get_env(:cinder, &1)})

    Application.put_env(:cinder, :filesystem, Cinder.Library.Filesystem.Disk)
    Application.put_env(:cinder, :path_policy, Cinder.Library.PathPolicy)
    Application.put_env(:cinder, :import_roots, [downloads])
    Application.put_env(:cinder, :explicit_import_roots, [downloads])
    Application.put_env(:cinder, :tv_library_path, tv)
    Application.put_env(:cinder, :move_on_import, false)

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:cinder, key)
        {key, value} -> Application.put_env(:cinder, key, value)
      end)
    end)

    stub(Cinder.Library.MediaServerMock, :scan, fn :tv -> :ok end)
    stub(Cinder.Download.ClientMock, :remove, fn _id, _opts -> :ok end)

    %{downloads: downloads, tv: tv}
  end
end
