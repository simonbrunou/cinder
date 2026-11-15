defmodule Cinder.Library.SeasonAdoptionTest do
  # Which files a requested season adopts without an operator (#720).
  use Cinder.DataCase, async: false

  import Mox
  import Cinder.CatalogFixtures

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Series}
  alias Cinder.Library.SeasonAdoption
  alias Cinder.Repo

  setup :verify_on_exit!

  @root "/tmp/cinder-test-tv-library"

  setup do
    series = series_fixture(%{tmdb_id: 4242, tvdb_id: 77, title: "Test Show", year: 2001})
    season = season_fixture(series, %{season_number: 1})
    episodes = for n <- 1..3, into: %{}, do: {n, episode_fixture(season, %{episode_number: n})}
    %{series: series, episodes: episodes}
  end

  # The root lists `folders`; each folder walks to its `files`.
  defp stub_library(tree) do
    stub(Cinder.Library.FilesystemMock, :ls, fn @root -> {:ok, Map.keys(tree)} end)

    stub(Cinder.Library.FilesystemMock, :find_files, fn folder ->
      case Map.fetch(tree, Path.relative_to(folder, @root)) do
        {:ok, files} -> {:ok, Enum.map(files, &{Path.join(folder, &1), 1_000_000_000})}
        :error -> {:error, :enoent}
      end
    end)
  end

  defp file_of(episode), do: Repo.reload!(episode).file_path

  test "a folder tagged with the show's tmdb id adopts the season's files", ctx do
    folder = "Test Show (2001) {tmdb-4242}"

    stub_library(%{
      folder => ["Season 01/Test.Show.S01E01.mkv", "Season 01/Test.Show.S01E02.mkv"]
    })

    assert {:done, ids} = SeasonAdoption.check(ctx.series, [1])
    assert Enum.sort(ids) == Enum.sort([ctx.episodes[1].id, ctx.episodes[2].id])

    assert file_of(ctx.episodes[1]) ==
             Path.join([@root, folder, "Season 01/Test.Show.S01E01.mkv"])

    assert file_of(ctx.episodes[2]) ==
             Path.join([@root, folder, "Season 01/Test.Show.S01E02.mkv"])

    assert file_of(ctx.episodes[3]) == nil
  end

  test "a folder tagged with the show's tvdb id adopts", ctx do
    stub_library(%{"Test Show {tvdb-77}" => ["Test.Show.S01E03.mkv"]})

    assert {:done, [id]} = SeasonAdoption.check(ctx.series, [1])
    assert id == ctx.episodes[3].id
  end

  test "a folder tagged with another show's id adopts nothing, whatever its title", ctx do
    stub_library(%{
      "Test Show (2001) {tmdb-999}" => ["Test.Show.S01E01.mkv"],
      "Test Show (2001) {tvdb-5}" => ["Test.Show.S01E02.mkv"]
    })

    # No TMDB stub: a tagged folder never falls back to the title rule.
    assert {:done, []} = SeasonAdoption.check(ctx.series, [1])
    assert file_of(ctx.episodes[1]) == nil
  end

  test "a title and year folder adopts when TMDB finds exactly that one show", ctx do
    stub_library(%{"Test Show (2001)" => ["Test.Show.S01E01.mkv"]})

    expect(Cinder.Catalog.TMDBMock, :search_tv, fn "Test Show", "en" ->
      {:ok,
       [
         %{tmdb_id: 4242, title: "Test Show", year: 2001},
         %{tmdb_id: 5, title: "Test Show", year: 2019}
       ]}
    end)

    assert {:done, [id]} = SeasonAdoption.check(ctx.series, [1])
    assert id == ctx.episodes[1].id
  end

  test "a title and year folder that names two shows adopts nothing", ctx do
    stub_library(%{"Test Show (2001)" => ["Test.Show.S01E01.mkv"]})

    expect(Cinder.Catalog.TMDBMock, :search_tv, fn "Test Show", "en" ->
      {:ok,
       [
         %{tmdb_id: 4242, title: "Test Show", year: 2001},
         %{tmdb_id: 5, title: "Test Show", year: 2001}
       ]}
    end)

    assert {:done, []} = SeasonAdoption.check(ctx.series, [1])
    assert file_of(ctx.episodes[1]) == nil
  end

  test "a title and year folder whose one show is another series adopts nothing", ctx do
    stub_library(%{"Test Show (2001)" => ["Test.Show.S01E01.mkv"]})

    expect(Cinder.Catalog.TMDBMock, :search_tv, fn "Test Show", "en" ->
      {:ok, [%{tmdb_id: 5, title: "Test Show", year: 2001}]}
    end)

    assert {:done, []} = SeasonAdoption.check(ctx.series, [1])
  end

  test "a folder of another title or year is never looked at", ctx do
    stub_library(%{
      "Other Show (2001)" => ["Test.Show.S01E01.mkv"],
      "Test Show (1999)" => ["Test.Show.S01E01.mkv"],
      "Test Show" => ["Test.Show.S01E01.mkv"]
    })

    stub(Cinder.Catalog.TMDBMock, :search_tv, fn query, _locale ->
      flunk("searched TMDB for #{query}")
    end)

    assert {:done, []} = SeasonAdoption.check(ctx.series, [1])
  end

  test "two files claiming one episode adopt neither, and the rest still adopts", ctx do
    folder = "Test Show (2001) {tmdb-4242}"

    stub_library(%{
      folder => ["A/Test.Show.S01E01.mkv", "B/Test.Show.S01E01.720p.mkv", "Test.Show.S01E02.mkv"]
    })

    assert {:done, [id]} = SeasonAdoption.check(ctx.series, [1])
    assert id == ctx.episodes[2].id
    assert file_of(ctx.episodes[1]) == nil
  end

  test "two folders of the show both count toward a duplicate claim", ctx do
    stub_library(%{
      "Test Show (2001) {tmdb-4242}" => ["Test.Show.S01E01.mkv"],
      "Test Show {tvdb-77}" => ["Test.Show.S01E01.mkv"]
    })

    assert {:done, []} = SeasonAdoption.check(ctx.series, [1])
  end

  test "a multi-episode file adopts every episode it names", ctx do
    stub_library(%{"Test Show {tmdb-4242}" => ["Test.Show.S01E01E02.mkv"]})

    assert {:done, ids} = SeasonAdoption.check(ctx.series, [1])
    assert Enum.sort(ids) == Enum.sort([ctx.episodes[1].id, ctx.episodes[2].id])
    assert file_of(ctx.episodes[1]) == file_of(ctx.episodes[2])
  end

  test "a sample, a non-video, an unparsed name, another season and an unknown episode stay",
       ctx do
    stub(Cinder.Library.FilesystemMock, :ls, fn @root -> {:ok, ["Test Show {tmdb-4242}"]} end)

    stub(Cinder.Library.FilesystemMock, :find_files, fn folder ->
      {:ok,
       [
         {Path.join(folder, "Test.Show.S01E01.sample.mkv"), 20_000_000},
         {Path.join(folder, "Test.Show.S01E02.nfo"), 100},
         {Path.join(folder, "Extras.mkv"), 1_000_000_000},
         {Path.join(folder, "Test.Show.S02E01.mkv"), 1_000_000_000},
         {Path.join(folder, "Test.Show.S01E09.mkv"), 1_000_000_000}
       ]}
    end)

    assert {:done, []} = SeasonAdoption.check(ctx.series, [1])
    assert Repo.aggregate(from(e in Episode, where: not is_nil(e.file_path)), :count) == 0
  end

  test "a season the approval did not arm keeps its files for /library/adopt", ctx do
    season_two = season_fixture(ctx.series, %{season_number: 2})
    s2e1 = episode_fixture(season_two, %{episode_number: 1})
    stub_library(%{"Test Show {tmdb-4242}" => ["Test.Show.S01E01.mkv", "Test.Show.S02E01.mkv"]})

    assert {:done, [id]} = SeasonAdoption.check(ctx.series, [1])
    assert id == ctx.episodes[1].id
    assert file_of(s2e1) == nil
  end

  test "a file another episode holds, and an episode with a grab, are left alone", ctx do
    folder = Path.join(@root, "Test Show {tmdb-4242}")
    other = episode_fixture(season_fixture(series_fixture(), %{season_number: 1}))

    {:ok, _} =
      Catalog.transition_episode(other, %{file_path: Path.join(folder, "Test.Show.S01E01.mkv")})

    {:ok, _grab} = Catalog.create_grab("active", :torrent, [ctx.episodes[2].id])

    stub_library(%{"Test Show {tmdb-4242}" => ["Test.Show.S01E01.mkv", "Test.Show.S01E02.mkv"]})

    assert {:done, []} = SeasonAdoption.check(ctx.series, [1])
    assert file_of(ctx.episodes[1]) == nil
    assert file_of(ctx.episodes[2]) == nil
  end

  test "an episode that already has a file keeps it", ctx do
    {:ok, _} = Catalog.transition_episode(ctx.episodes[1], %{file_path: "/elsewhere/E01.mkv"})
    stub_library(%{"Test Show {tmdb-4242}" => ["Test.Show.S01E01.mkv"]})

    assert {:done, []} = SeasonAdoption.check(ctx.series, [1])
    assert file_of(ctx.episodes[1]) == "/elsewhere/E01.mkv"
  end

  test "the adoption keeps the profile the approval gave the series", ctx do
    series = Repo.update!(Ecto.Changeset.change(ctx.series, media_profile: :standard))
    stub_library(%{"Test Show {tmdb-4242}" => ["Test.Show.S01E01.mkv"]})

    assert {:done, [_id]} = SeasonAdoption.check(series, [1])
    assert %Series{media_profile: :standard, profile_id: nil} = Repo.reload!(series)
  end

  test "an anime series or one with a scene numbering group adopts nothing and reads no file",
       ctx do
    # No FilesystemMock stub: a read would raise.
    anime = Repo.update!(Ecto.Changeset.change(ctx.series, media_profile: :anime))
    assert {:done, []} = SeasonAdoption.check(anime, [1])

    scene = Repo.update!(Ecto.Changeset.change(ctx.series, scene_numbering_group_id: "group"))
    assert {:done, []} = SeasonAdoption.check(scene, [1])
  end

  test "a missing TV root adopts nothing", ctx do
    stub(Cinder.Library.FilesystemMock, :ls, fn @root -> {:error, :enoent} end)
    assert {:done, []} = SeasonAdoption.check(ctx.series, [1])
  end

  test "a root that cannot be listed, a folder walk that fails and a TMDB error hold", ctx do
    stub(Cinder.Library.FilesystemMock, :ls, fn @root -> {:error, :eio} end)
    assert {:hold, {:list_failed, @root, :eio}} = SeasonAdoption.check(ctx.series, [1])

    stub(Cinder.Library.FilesystemMock, :ls, fn @root -> {:ok, ["Test Show {tmdb-4242}"]} end)
    stub(Cinder.Library.FilesystemMock, :find_files, fn _folder -> {:error, :eacces} end)
    assert {:hold, {:walk_failed, @root, :eacces}} = SeasonAdoption.check(ctx.series, [1])

    stub(Cinder.Library.FilesystemMock, :ls, fn @root -> {:ok, ["Test Show (2001)"]} end)
    expect(Cinder.Catalog.TMDBMock, :search_tv, fn "Test Show", "en" -> {:error, :timeout} end)
    assert {:hold, {:tmdb_search_failed, :timeout}} = SeasonAdoption.check(ctx.series, [1])
  end
end
