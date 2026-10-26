defmodule Cinder.Catalog.AnimeHoldTest do
  @moduledoc """
  The operator's fix lifts an anime hold at once, without waiting for a sweep to visit the title
  (#791): a profile or Audio pick change decides the hold again, and unmonitoring a series' last
  monitored episode lifts it. None of them sets a hold on a title that has none.

  The settings-save trigger is pinned in `Cinder.SettingsTest`, and the sweeps' own decision in
  `PollerTest`, `TvPollerTest` and `UpgradeHunterTest`.
  """
  # async: false: the anime defaults are global Application env.
  use Cinder.DataCase, async: false

  import Mox
  import Cinder.CatalogFixtures
  import Cinder.ConfigCase, only: [put_config: 2]

  alias Cinder.Acquisition.AnimePreferences
  alias Cinder.Catalog
  alias Cinder.Catalog.{Attention, Episode, Movie, Series}
  alias Cinder.Repo
  alias Cinder.Settings

  setup :verify_on_exit!

  # Embedded subtitles required with no subtitle language set: every Anime title fails on
  # `subtitle_language_required` until the operator sets one.
  defp require_subtitles!, do: put_config(:anime_preferences, embedded_subtitle_mode: :require)

  defp held(title, reason), do: anime_hold_fixture(title, reason)
  defp hold(title), do: Repo.reload!(title).anime_hold_reason

  defp standard_profile(kind),
    do: Enum.find(Catalog.list_profiles(kind), &(&1.handling == :standard))

  describe "a profile or Audio pick change" do
    test "a held series whose Audio pick now resolves loses its hold, and the count drops" do
      # Dual audio needs the original language, which this series does not know.
      series =
        held(
          series_fixture(%{media_profile: :anime, preferred_language: "dual"}),
          "original_language_required"
        )

      count = Attention.attention_count()
      Catalog.subscribe_series()

      assert {:ok, %Series{anime_hold_reason: nil}} =
               Catalog.set_series_language(series, "french")

      assert hold(series) == nil
      assert Attention.attention_count() == count - 1
      assert_received {:series_updated, id} when id == series.id
    end

    test "a held movie whose Audio pick now resolves loses its hold" do
      movie = movie_fixture(%{media_profile: :anime})
      {:ok, movie} = Catalog.set_movie_language(movie, "dual")
      movie = held(movie, "original_language_required")
      count = Attention.attention_count()
      Catalog.subscribe()

      assert {:ok, %Movie{anime_hold_reason: nil}} = Catalog.set_movie_language(movie, "french")

      assert hold(movie) == nil
      assert Attention.attention_count() == count - 1
      assert_received {:movie_updated, %Movie{anime_hold_reason: nil}}
    end

    # The detail pages switch a profile through `assign_profile/2`. It refuses a searching movie
    # (an acquisition is in progress), so the movie here waits as requested.
    test "a held movie and a held series assigned the Standard profile lose their hold" do
      require_subtitles!()
      movie = held(movie_fixture(%{media_profile: :anime}), "subtitle_language_required")
      series = held(series_fixture(%{media_profile: :anime}), "subtitle_language_required")
      count = Attention.attention_count()
      Catalog.subscribe()

      assert {:ok, %Movie{anime_hold_reason: nil}} =
               Catalog.assign_profile(movie, standard_profile(:movies))

      assert {:ok, %Series{anime_hold_reason: nil}} =
               Catalog.assign_profile(series, standard_profile(:tv))

      assert hold(movie) == nil
      assert hold(series) == nil
      assert Attention.attention_count() == count - 2
      assert_received {:movie_updated, %Movie{anime_hold_reason: nil}}
    end

    # Adopting on-disk files into a profile's library assigns that profile to the series.
    test "adopting files into the Standard profile lifts a held series' hold" do
      require_subtitles!()
      series = held(series_fixture(%{media_profile: :anime}), "subtitle_language_required")
      episode = episode_fixture(season_fixture(series))
      action = %{episode: episode, type: :primary, path: "/tmp/hold-791/S01E01.mkv"}

      assert {:ok, [_adopted]} =
               Catalog.adopt_series_files(
                 series,
                 [action],
                 standard_profile(:tv).id,
                 :auto,
                 fn _profile -> :ok end
               )

      assert hold(series) == nil
    end

    test "an approval-path profile write on a held title lifts its hold" do
      require_subtitles!()
      movie = held(movie_fixture(%{media_profile: :anime}), "subtitle_language_required")
      series = held(series_fixture(%{media_profile: :anime}), "subtitle_language_required")
      count = Attention.attention_count()

      assert {:ok, %Movie{anime_hold_reason: nil}} = Catalog.set_media_profile(movie, :standard)
      assert {:ok, %Series{anime_hold_reason: nil}} = Catalog.set_media_profile(series, :standard)

      assert hold(movie) == nil
      assert hold(series) == nil
      assert Attention.attention_count() == count - 2
    end

    # Auto searches through Anime only as a Japanese animation's fallback. No profile is Auto.
    test "Auto lifts the hold of a title with no anime fallback and keeps a fallback title's" do
      require_subtitles!()
      plain = held(series_fixture(%{media_profile: :anime}), "subtitle_language_required")

      fallback =
        series_fixture(%{media_profile: :anime, original_language: "ja", genres: ["Animation"]})
        |> held("subtitle_language_required")

      assert {:ok, _plain} = Catalog.assign_profile(plain, nil)
      assert {:ok, _fallback} = Catalog.assign_profile(fallback, nil)

      assert hold(plain) == nil
      assert hold(fallback) == "subtitle_language_required"
    end

    # A detail page writes from the struct it read, which can predate the sweep's last write.
    test "the row's hold decides, not the hold on the caller's struct" do
      require_subtitles!()
      read_before_hold = series_fixture(%{media_profile: :anime, preferred_language: "dual"})
      held(read_before_hold, "original_language_required")

      assert {:ok, %Series{anime_hold_reason: "subtitle_language_required"}} =
               Catalog.set_series_language(read_before_hold, "french")

      read_while_held =
        series_fixture(%{media_profile: :anime, preferred_language: "dual"})
        |> held("original_language_required")

      {:ok, _lifted} = Catalog.set_anime_hold(read_while_held, nil)

      # French audio still fails on subtitles, but the row holds nothing, so nothing is set.
      assert {:ok, %Series{anime_hold_reason: nil}} =
               Catalog.set_series_language(read_while_held, "french")

      assert hold(read_before_hold) == "subtitle_language_required"
      assert hold(read_while_held) == nil
    end

    test "a fix that leaves the preferences failing keeps the hold or names the new reason" do
      require_subtitles!()

      series =
        held(
          series_fixture(%{media_profile: :anime, preferred_language: "dual"}),
          "original_language_required"
        )

      movie = held(movie_fixture(%{media_profile: :anime}), "subtitle_language_required")

      # French audio resolves, then the subtitle requirement fails.
      assert {:ok, %Series{anime_hold_reason: "subtitle_language_required"}} =
               Catalog.set_series_language(series, "french")

      assert {:ok, %Movie{anime_hold_reason: "subtitle_language_required"}} =
               Catalog.set_movie_language(movie, "french")

      assert hold(series) == "subtitle_language_required"
      assert hold(movie) == "subtitle_language_required"
    end

    test "a title with no hold gets none, even when its preferences fail" do
      require_subtitles!()
      movie = movie_fixture(%{media_profile: :anime})
      series = series_fixture(%{media_profile: :auto})

      assert {:ok, movie} = Catalog.set_movie_language(movie, "french")
      assert {:ok, series} = Catalog.set_media_profile(series, :anime)
      assert {:ok, series} = Catalog.set_series_language(series, "french")

      # Both fail to resolve, so a trigger that set holds would have set one here.
      for title <- [movie, series] do
        assert {:error, :subtitle_language_required} =
                 AnimePreferences.resolve(title, Settings.anime_defaults())

        assert hold(title) == nil
      end
    end
  end

  describe "unmonitoring a held series' last monitored episode" do
    setup do
      stub(Cinder.Library.FilesystemMock, :rm, fn _path -> :ok end)
      stub(Cinder.Library.FilesystemMock, :rmdir, fn _path -> {:error, :enotempty} end)
      :ok
    end

    # One aired episode with a file, monitored, in a held Anime series.
    defp held_series_tree do
      series =
        series_fixture(%{media_profile: :anime, monitor_strategy: :all})
        |> held("subtitle_language_required")

      season = season_fixture(series)
      episode = episode_fixture(season, %{file_path: "/tmp/hold-791/S01E01.mkv"})
      {series, season, episode}
    end

    # Every write that turns `episode.monitored` off.
    defp unmonitor(:episode, _series, _season, episode),
      do: Catalog.set_episode_monitored(episode, false)

    defp unmonitor(:season, _series, season, _episode),
      do: Catalog.set_season_monitored(season, false)

    defp unmonitor(:episode_file, _series, _season, episode),
      do: Catalog.delete_episode_file(episode, nil, unmonitor: true)

    defp unmonitor(:season_files, _series, season, _episode),
      do: Catalog.delete_season_files(season, nil, unmonitor: true)

    # `:future` drops the aired episode and keeps an undated one.
    defp unmonitor(:strategy, series, _season, _episode),
      do: Catalog.set_series_monitor_strategy(series, :future)

    for route <- [:episode, :season, :episode_file, :season_files, :strategy] do
      test "#{route}: the last one lifts the hold" do
        {series, season, episode} = held_series_tree()
        count = Attention.attention_count()

        assert {:ok, _} = unmonitor(unquote(route), series, season, episode) |> ok_tuple()

        refute Repo.get!(Episode, episode.id).monitored
        assert hold(series) == nil
        assert Attention.attention_count() == count - 1
      end

      test "#{route}: one of several keeps the hold" do
        {series, season, episode} = held_series_tree()
        other_season = season_fixture(series, %{season_number: 2})
        other = episode_fixture(other_season, %{air_date: nil})

        assert {:ok, _} = unmonitor(unquote(route), series, season, episode) |> ok_tuple()

        refute Repo.get!(Episode, episode.id).monitored
        assert Repo.get!(Episode, other.id).monitored
        assert hold(series) == "subtitle_language_required"
      end
    end

    # `delete_season_files/3` answers `{:ok, cleared, failed}`.
    defp ok_tuple({:ok, cleared, _failed}), do: {:ok, cleared}
    defp ok_tuple(result), do: result
  end
end
