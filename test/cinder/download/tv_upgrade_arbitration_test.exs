defmodule Cinder.Download.TvUpgradeArbitrationTest do
  @moduledoc """
  #250: a sweep-initiated upgrade grab (`Grab.arbitrate_at_import`) lets the IMPORT decide each
  episode's swap, so a season pack that improves only part of a season can be taken — the
  episodes it beats get the new file, the rest keep theirs. The manual path still forces.

  Real filesystem on purpose: the bug this covers is that a declined release used to still land,
  because the destination path carries the *source's* extension and so never collided with the
  file the episode already held.
  """
  use Cinder.DataCase, async: false

  import Mox
  import Cinder.CatalogFixtures

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Grab, GrabFile}
  alias Cinder.Download.TvPoller
  alias Cinder.Repo

  setup :set_mox_global

  @tag :tmp_dir
  test "a sweep pack upgrades what it beats and leaves the rest alone", %{tmp_dir: tmp} do
    %{release_dir: release_dir, library: library, episodes: episodes} = partly_better_pack(tmp)

    {:ok, grab} = arbitrated_grab(episodes, release_dir)

    start_supervised!({TvPoller, interval: 60_000})
    assert :ok = TvPoller.poll()

    # The two the pack beats took the new file.
    for number <- [1, 3] do
      episode = reload(episodes, number)

      assert episode.file_path ==
               Path.join(library, "Show (2008) {tmdb-4242} - S01E0#{number}.mkv")

      assert File.exists?(episode.file_path)
      assert episode.imported_resolution == "1080p"
    end

    # The two it doesn't keep exactly what they had — path, bytes and recorded quality. E02 is the
    # regression case: its incoming file is .mp4, so the destination never collided with the .mkv
    # on disk and the worse release used to be placed and the better file then deleted.
    for number <- [2, 4] do
      episode = reload(episodes, number)

      assert episode.file_path ==
               Path.join(library, "Show (2008) {tmdb-4242} - S01E0#{number}.mkv")

      assert File.read!(episode.file_path) == "held-#{number}"
      assert episode.imported_resolution == "1080p"
      assert episode.imported_size == 9_000_000_000
    end

    # Clean close: no residual holds, no leftover admin action, grab gone.
    refute Repo.get(Grab, grab.id)
    assert Repo.all(GrabFile) == []
    assert Catalog.count_operator_holds() == 0
  end

  @tag :tmp_dir
  test "a manual grab still forces the swap", %{tmp_dir: tmp} do
    %{release_dir: release_dir, library: library, episodes: episodes} = partly_better_pack(tmp)

    {:ok, _grab} = manual_grab(episodes, release_dir)

    start_supervised!({TvPoller, interval: 60_000})
    assert :ok = TvPoller.poll()

    # E04's release is strictly worse (720p over 1080p) and it lands anyway: the operator picked
    # this release, possibly for something the ranking can't see.
    episode = reload(episodes, 4)
    assert episode.file_path == Path.join(library, "Show (2008) {tmdb-4242} - S01E04.mkv")
    assert File.read!(episode.file_path) == "release-4"
    assert episode.imported_resolution == "720p"
  end

  @tag :tmp_dir
  test "a declined double-episode file leaves each episode on its own file", %{tmp_dir: tmp} do
    %{downloads: downloads, tv: tv} = real_tv_library(tmp)

    release_dir = Path.join(downloads, "Show.S01E05E06.720p.WEB-DL-GRP")
    File.mkdir_p!(release_dir)
    File.write!(Path.join(release_dir, "Show.S01E05E06.720p.WEB-DL.mkv"), "combined")

    library = Path.join([tv, "Show (2008) {tmdb-4243}", "Season 01"])
    File.mkdir_p!(library)

    series = series_fixture(%{tmdb_id: 4243, title: "Show", year: 2008, monitor_strategy: :all})
    season = season_fixture(series)

    # Two 1080p BluRay episodes held as SEPARATE files. The incoming file covers both and beats
    # neither: collapsing them onto one path would strand the other's file for deletion.
    episodes =
      for number <- [5, 6] do
        held = Path.join(library, "Show (2008) {tmdb-4243} - S01E0#{number}.mkv")
        File.write!(held, "held-#{number}")

        episode_fixture(season, %{
          episode_number: number,
          file_path: held,
          imported_resolution: "1080p",
          imported_source: "BLURAY",
          imported_size: 9_000_000_000
        })
      end

    {:ok, grab} = arbitrated_grab(episodes, release_dir)

    start_supervised!({TvPoller, interval: 60_000})
    assert :ok = TvPoller.poll()

    for number <- [5, 6] do
      episode = reload(episodes, number)

      assert episode.file_path ==
               Path.join(library, "Show (2008) {tmdb-4243} - S01E0#{number}.mkv")

      assert File.read!(episode.file_path) == "held-#{number}"
    end

    refute Repo.get(Grab, grab.id)
    assert Catalog.count_operator_holds() == 0
  end

  # `import_stages.dest` is globally unique and two episodes legitimately share one `file_path` —
  # what a previously imported double-episode file leaves behind. A stage each would collide. The
  # two cases differ by whether the decline happens in one staging group or two.
  for {label, incoming} <- [
        {"one combined incoming file", ["Show.S01E07E08.720p.WEB-DL.mkv"]},
        {"two separate incoming files",
         ["Show.S01E07.720p.WEB-DL.mkv", "Show.S01E08.720p.WEB-DL.mkv"]}
      ] do
    @tag :tmp_dir
    @incoming incoming
    test "a decline against one shared held file stages it once (#{label})", %{tmp_dir: tmp} do
      %{downloads: downloads, tv: tv} = real_tv_library(tmp)

      release_dir = Path.join(downloads, "Show.S01.720p.WEB-DL-GRP")
      File.mkdir_p!(release_dir)
      Enum.each(@incoming, &File.write!(Path.join(release_dir, &1), "incoming"))

      library = Path.join([tv, "Show (2008) {tmdb-4244}", "Season 01"])
      File.mkdir_p!(library)

      series = series_fixture(%{tmdb_id: 4244, title: "Show", year: 2008, monitor_strategy: :all})
      season = season_fixture(series)

      held = Path.join(library, "Show (2008) {tmdb-4244} - S01E07-E08.mkv")
      File.write!(held, "held-both")

      episodes =
        for number <- [7, 8] do
          episode_fixture(season, %{
            episode_number: number,
            file_path: held,
            imported_resolution: "1080p",
            imported_source: "BLURAY",
            imported_size: 9_000_000_000
          })
        end

      {:ok, grab} = arbitrated_grab(episodes, release_dir)

      start_supervised!({TvPoller, interval: 60_000})
      assert :ok = TvPoller.poll()

      for number <- [7, 8] do
        assert reload(episodes, number).file_path == held
      end

      assert File.read!(held) == "held-both"
      # Imported, not parked: a dest collision would have failed the grab and retried it.
      refute Repo.get(Grab, grab.id)
      assert Catalog.count_operator_holds() == 0
    end
  end

  # E01/E03 are 480p and the pack beats them; E02/E04 are 1080p BluRay at 9 GB and it does not.
  # E02's incoming file is .mp4 so its destination differs from the .mkv already held.
  defp partly_better_pack(tmp) do
    %{downloads: downloads, tv: tv} = real_tv_library(tmp)

    release_dir = Path.join(downloads, "Show.S01.1080p.WEB-DL-GRP")
    File.mkdir_p!(release_dir)
    library = Path.join([tv, "Show (2008) {tmdb-4242}", "Season 01"])
    File.mkdir_p!(library)

    series = series_fixture(%{tmdb_id: 4242, title: "Show", year: 2008, monitor_strategy: :all})
    season = season_fixture(series)

    episodes =
      for {number, resolution, extension} <- [
            {1, "480p", "mkv"},
            {2, "1080p", "mp4"},
            {3, "480p", "mkv"},
            {4, "1080p", "mkv"}
          ] do
        File.write!(
          Path.join(release_dir, "Show.S01E0#{number}.#{incoming(number)}.WEB-DL.#{extension}"),
          "release-#{number}"
        )

        held = Path.join(library, "Show (2008) {tmdb-4242} - S01E0#{number}.mkv")
        File.write!(held, "held-#{number}")

        episode_fixture(season, %{
          episode_number: number,
          file_path: held,
          imported_resolution: resolution,
          imported_source: if(resolution == "1080p", do: "BLURAY", else: "WEBDL"),
          imported_size: if(resolution == "1080p", do: 9_000_000_000, else: 700_000_000)
        })
      end

    %{release_dir: release_dir, library: library, episodes: episodes}
  end

  defp incoming(number) when number in [1, 3], do: "1080p"
  defp incoming(_number), do: "720p"

  defp arbitrated_grab(episodes, release_dir),
    do: downloaded_grab(episodes, release_dir, arbitrate_at_import: true)

  defp manual_grab(episodes, release_dir), do: downloaded_grab(episodes, release_dir, [])

  defp downloaded_grab(episodes, release_dir, opts) do
    {:ok, grab} =
      Catalog.create_grab(
        "arb-#{System.unique_integer([:positive])}",
        :usenet,
        Enum.map(episodes, & &1.id),
        "Show.S01.1080p.WEB-DL-GRP",
        [allow_available: true] ++ opts
      )

    Catalog.mark_grab_downloaded(grab, release_dir)
  end

  defp reload(episodes, number) do
    Repo.get!(Episode, Enum.find(episodes, &(&1.episode_number == number)).id)
  end

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
