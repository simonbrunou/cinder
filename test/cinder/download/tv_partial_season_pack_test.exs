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
  test "another series' episode is never dropped, even when our numbering claims it", %{
    tmp_dir: tmp
  } do
    # `match_arm/2` compares season and episode numbers only — never the show name. A foreign
    # S01E05 bundled into this pack is therefore claimed by the S01E05 we hold, and without a name
    # check it would be discarded with the download, unseen.
    %{grab: grab} =
      partial_season_pack(tmp, ["Totally.Different.Show.S01E05.1080p.WEB-DL.mkv"])

    start_supervised!({TvPoller, interval: 60_000})
    assert :ok = TvPoller.poll()

    grab = Repo.get!(Grab, grab.id) |> Repo.preload(:grab_files)

    assert Enum.map(grab.grab_files, & &1.relative_path) == [
             "Totally.Different.Show.S01E05.1080p.WEB-DL.mkv"
           ]

    assert Grabs.grab_hold(grab) == :residual_files
  end

  @tag :tmp_dir
  test "a name that merely EXTENDS ours is a decision, not a discard", %{tmp_dir: tmp} do
    # "Show.US" is a different show, the same way "Law & Order: SVU" is not "Law & Order". An
    # unrecognised token between the title and the release tags means we can't be sure, and an
    # operator hold is recoverable where a deleted file is not.
    %{grab: grab} = partial_season_pack(tmp, ["Show.US.S01E05.1080p.WEB-DL.mkv"])

    start_supervised!({TvPoller, interval: 60_000})
    assert :ok = TvPoller.poll()

    grab = Repo.get!(Grab, grab.id) |> Repo.preload(:grab_files)
    assert Enum.map(grab.grab_files, & &1.relative_path) == ["Show.US.S01E05.1080p.WEB-DL.mkv"]
  end

  @tag :tmp_dir
  test "a same-titled show from another year is a decision, not a discard", %{tmp_dir: tmp} do
    # A year token only reads as OUR release tag when it is our year — the same discriminator
    # `reject_year_conflicts/2` uses for "Charmed (2018)" against the 1998 series.
    %{grab: grab} = partial_season_pack(tmp, ["Show.1999.S01E05.1080p.WEB-DL.mkv"])

    start_supervised!({TvPoller, interval: 60_000})
    assert :ok = TvPoller.poll()

    grab = Repo.get!(Grab, grab.id) |> Repo.preload(:grab_files)
    assert Enum.map(grab.grab_files, & &1.relative_path) == ["Show.1999.S01E05.1080p.WEB-DL.mkv"]
  end

  # The whole point of going through `Acquisition.names_title?/2` instead of a local fold: these
  # are the shapes a hand-rolled downcase-and-split gets wrong, and getting them wrong puts every
  # already-held file of such a series back into the operator hold #251 removed. The glued
  # multi-episode and `1x05` forms are here for the same reason — `Parser.parse/1` claims them, so
  # the guard has to confirm them or the hold re-opens for exactly the combined-episode files.
  for {title, file} <- [
        {"Grey's Anatomy", "Greys.Anatomy.S01E05.1080p.WEB-DL.mkv"},
        {"Law & Order", "Law.and.Order.S01E05.1080p.WEB-DL.mkv"},
        {"S.W.A.T.", "SWAT.S01E05.1080p.WEB-DL.mkv"},
        {"Pokémon", "Pokemon.S01E05.1080p.WEB-DL.mkv"},
        {"Show", "Show.2008.S01E05.1080p.WEB-DL.mkv"},
        {"Show", "Show.S01E05E06.1080p.WEB-DL.mkv"},
        {"Show", "Show.1x05.1080p.WEB-DL.mkv"}
      ] do
    @tag :tmp_dir
    @series_title title
    @scene_file file
    test "#{title} still recognises #{file} as its own", %{tmp_dir: tmp} do
      # Only the two wanted episodes get standalone files (they import through the title-blind
      # claiming pass), so the file under test is the sole candidate residual: it survives as a
      # `grab_file` if the fold fails to recognise it, and vanishes if it works.
      %{grab: grab} = partial_season_pack(tmp, [@scene_file], title: @series_title, pack: [9, 10])

      start_supervised!({TvPoller, interval: 60_000})
      assert :ok = TvPoller.poll()

      assert Repo.all(GrabFile) == []
      refute Repo.get(Grab, grab.id)
    end
  end

  @tag :tmp_dir
  test "a two-parter spanning a held and a wanted episode stays a decision", %{tmp_dir: tmp} do
    # E08 is in the library, E09 is not, so `Show.S01E08E09.mkv` names one episode we hold and one
    # we don't. It loses `dedupe_per_episode/1` to the pack's own bigger S01E09 file, so nothing is
    # at risk here — this pins the classification alone. The test below covers the case where the
    # two-parter really is the only candidate.
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

  @tag :tmp_dir
  test "a two-parter that is a wanted episode's only candidate is never discarded", %{
    tmp_dir: tmp
  } do
    # E09 is wanted but NOT linked to this grab, and the pack ships no standalone E09 file — so
    # `Show.S01E08E09.mkv` is the only thing that could ever give E09 its file. Dropping it as
    # "already held" (E08 claims it) deletes it with the download under move_on_import.
    %{grab: grab, unlinked: e09} =
      partial_season_pack(tmp, ["Show.S01E08E09.1080p.WEB-DL.mkv"], link: [10], pack: [10])

    start_supervised!({TvPoller, interval: 60_000})
    assert :ok = TvPoller.poll()

    grab = Repo.get!(Grab, grab.id) |> Repo.preload(:grab_files)

    assert Enum.map(grab.grab_files, & &1.relative_path) == ["Show.S01E08E09.1080p.WEB-DL.mkv"]
    assert Grabs.grab_hold(grab) == :residual_files

    # Still wanted, still unimported — but its candidate survived for the operator to decide on.
    assert Repo.get!(Episode, e09.id).file_path == nil
  end

  # A 10-episode season: E01–E08 already in the library, E09–E10 wanted. `pack:` is which episodes
  # get a standalone file in the release, `link:` which the grab claims (the sweep links only what
  # it searched for — that is what leaves the rest unclaimed at import).
  defp partial_season_pack(tmp, extra_files, opts \\ []) do
    packed = Keyword.get(opts, :pack, Enum.to_list(1..10))
    linked = Keyword.get(opts, :link, [9, 10])
    title = Keyword.get(opts, :title, "Show")

    %{downloads: downloads, tv: tv} = real_tv_library(tmp)

    release_dir = Path.join(downloads, "Show.S01.1080p.WEB-DL-GRP")
    File.mkdir_p!(release_dir)

    for number <- packed do
      File.write!(
        Path.join(release_dir, "Show.S01E#{pad(number)}.1080p.WEB-DL.mkv"),
        "release-#{number}"
      )
    end

    Enum.each(extra_files, &File.write!(Path.join(release_dir, &1), "extra"))

    series = series_fixture(%{tmdb_id: 7788, tvdb_id: 7788, title: title, year: 2008})
    season = season_fixture(series)

    show = "#{library_title(title)} (2008) {tmdb-7788}"
    library = Path.join([tv, show, "Season 01"])
    File.mkdir_p!(library)

    held =
      for number <- 1..8 do
        path = Path.join(library, "#{show} - S01E#{pad(number)}.mkv")
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
    {to_link, unlinked} = Enum.split_with(wanted, &(&1.episode_number in linked))

    {:ok, grab} =
      Catalog.create_grab(
        "partial-#{System.unique_integer([:positive])}",
        :usenet,
        Enum.map(to_link, & &1.id),
        "Show.S01.1080p.WEB-DL-GRP"
      )

    {:ok, grab} = Catalog.mark_grab_downloaded(grab, release_dir)

    %{grab: grab, wanted: to_link, held: held, unlinked: List.first(unlinked)}
  end

  # Mirrors Cinder.Library.Naming's folder name for the titles these tests use.
  defp library_title(title),
    do:
      title
      |> String.replace(["/", "\\", ":", "*", "?", "\"", "<", ">", "|"], "")
      |> String.trim()

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

    # An episode left wanted by the import reaches the poller's search phase. Stub it to find
    # nothing rather than leaving it unstubbed: `isolate/2` swallows the resulting raise, so the
    # sweep would be stopped by a crash the test can't see, and later assertions would be vacuous.
    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn _tvdb_id, _title, _season -> {:ok, []} end)

    %{downloads: downloads, tv: tv}
  end
end
