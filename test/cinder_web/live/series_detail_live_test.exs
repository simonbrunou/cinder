defmodule CinderWeb.SeriesDetailLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import Cinder.AccountsFixtures
  import Cinder.CatalogFixtures

  alias Cinder.{Catalog, Repo}
  alias Cinder.Catalog.{Grab, Series, TitleAlias}

  setup :register_and_log_in_admin
  setup :set_mox_global

  # Baseline so every detail-page metadata refresh resolves for tests that build a series directly.
  # Nil metadata never injects unexpected strings; create_series/1 overrides this stub per test.
  setup do
    stub(Cinder.Catalog.TMDBMock, :get_series, fn tmdb_id ->
      {:ok, base_series_info(tmdb_id)}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_series_alternative_titles, fn _ -> {:ok, []} end)
    stub(Cinder.Catalog.TMDBMock, :get_episode_groups, fn _ -> {:ok, []} end)

    :ok
  end

  defp base_series_info(tmdb_id) do
    %{
      tmdb_id: tmdb_id,
      tvdb_id: nil,
      title: "S",
      year: 2020,
      poster_path: nil,
      original_language: "en",
      overview: nil,
      genres: nil,
      vote_average: nil,
      first_air_date: nil,
      seasons: []
    }
  end

  # Build a series tree directly via the context (mocked TMDB), at :none so every
  # episode starts un-monitored — the toggles then have something to flip.
  defp create_series(tmdb_id) do
    # Non-pinned so tests can open more than one locally-created series with this shared response.
    stub(Cinder.Catalog.TMDBMock, :get_series, fn _ ->
      {:ok,
       %{
         base_series_info(tmdb_id)
         | title: "Test Show",
           overview: "A test show overview.",
           genres: ["Drama"],
           vote_average: 8.2,
           first_air_date: ~D[2020-01-01],
           seasons: [%{season_number: 1}]
       }}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_season, fn ^tmdb_id, 1 ->
      {:ok,
       %{
         season_number: 1,
         episodes: [
           %{tmdb_episode_id: 1, episode_number: 1, title: "Pilot", air_date: ~D[2020-01-01]},
           %{tmdb_episode_id: 2, episode_number: 2, title: "Two", air_date: ~D[2020-01-08]}
         ]
       }}
    end)

    {:ok, series} = Catalog.add_series(tmdb_id, monitor_strategy: :none)

    # Keep the persisted metadata in sync with the stubbed detail response so the page refresh
    # can't erase it while these tests focus on the tree and toggle behavior.
    series
    |> Ecto.Changeset.change(%{
      overview: "A test show overview.",
      genres: ["Drama"],
      vote_average: 8.2,
      first_air_date: ~D[2020-01-01]
    })
    |> Repo.update!()
  end

  defp first_episode(series_id) do
    Catalog.get_series_with_tree(series_id).seasons |> hd() |> Map.fetch!(:episodes) |> hd()
  end

  defp first_season(series_id) do
    Catalog.get_series_with_tree(series_id).seasons |> hd()
  end

  # A connected detail mount always starts :enrich. Drain it before returning so its DB work cannot
  # outlive the SQL sandbox owner at the end of the test.
  defp live_series(conn, series, drain? \\ true) do
    {:ok, view, html} = live(conn, ~p"/series/#{series.id}")
    on_exit(fn -> stop_live_view(view) end)

    if drain? do
      render_async(view)
      {:ok, view, render(view)}
    else
      {:ok, view, html}
    end
  end

  defp stop_live_view(view) do
    if Process.alive?(view.pid), do: GenServer.stop(view.pid)
  catch
    :exit, _reason -> :ok
  end

  defp anime_preferences_params(overrides \\ %{}) do
    Map.merge(
      %{
        "audio_mode" => "dual",
        "embedded_subtitle_mode" => "require",
        "subtitle_languages_mode" => "override",
        "subtitle_languages" => "fr",
        "preferred_release_groups_mode" => "override",
        "preferred_release_groups" => "SubsPlease, subsplease",
        "blocked_release_groups_mode" => "override",
        "blocked_release_groups" => "BadGroup",
        "group_fallback_delay_mode" => "override",
        "group_fallback_delay_hours" => "6"
      },
      overrides
    )
  end

  defp put_nonempty_anime_defaults! do
    anime = Application.fetch_env!(:cinder, :anime_preferences)
    subtitles = Application.get_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, [])

    Application.put_env(
      :cinder,
      :anime_preferences,
      Keyword.merge(anime, preferred_groups: ["subsplease"], blocked_groups: ["badgroup"])
    )

    Application.put_env(
      :cinder,
      Cinder.Subtitles.Provider.OpenSubtitles,
      Keyword.put(subtitles, :languages, "fr,en")
    )

    on_exit(fn ->
      Application.put_env(:cinder, :anime_preferences, anime)
      Application.put_env(:cinder, Cinder.Subtitles.Provider.OpenSubtitles, subtitles)
    end)
  end

  test "admin changes a series profile and manages sourced aliases", %{conn: conn} do
    series = create_series(6_900)

    provider =
      %TitleAlias{series_id: series.id}
      |> TitleAlias.changeset(%{
        title: "Provider title",
        kind: :native,
        source: "tmdb",
        namespace: "alternative_titles",
        precedence: :curated
      })
      |> Repo.insert!()

    {:ok, view, _} = live_series(conn, series)

    view
    |> form("#series-profile-form", %{"media_profile" => "anime"})
    |> render_change()

    assert Repo.reload(series).media_profile == :anime

    view
    |> form("#series-alias-form", %{
      "alias" => %{
        "title" => "Shingeki no Kyojin",
        "kind" => "romaji",
        "country_code" => "JP",
        "language_code" => "ja"
      }
    })
    |> render_submit()

    assert has_element?(view, "#series-title-aliases [data-alias='Shingeki no Kyojin']")
    assert has_element?(view, "[data-alias='Provider title'][data-source='tmdb']")
    refute has_element?(view, "#edit-series-alias-#{provider.id}")
    refute has_element?(view, "#delete-series-alias-#{provider.id}")

    manual = Enum.find(Catalog.list_title_aliases(series), &(&1.precedence == :manual))

    refute has_element?(view, "#series-alias-edit-status")
    refute has_element?(view, "#edit-series-alias-#{manual.id}[phx-click*='focus']")
    assert has_element?(view, "#edit-series-alias-#{manual.id}[phx-click*='push']")

    view
    |> element("#edit-series-alias-#{manual.id}")
    |> render_click()

    assert has_element?(
             view,
             "#series-alias-edit-status[role='status'][phx-mounted*='focus'][phx-mounted*='#series-alias-title']",
             "Editing alias Shingeki no Kyojin"
           )
  end

  test "admin saves series Anime preferences and stored overrides stay dormant while Standard", %{
    conn: conn
  } do
    series =
      series_fixture(%{
        media_profile: :anime,
        original_language: "ja",
        preferred_language: "french"
      })

    {:ok, view, _} = live_series(conn, series)
    assert has_element?(view, "#anime-preferences-form")

    view
    |> form("#anime-preferences-form", anime_preferences: anime_preferences_params())
    |> render_submit()

    fresh = Repo.reload!(series)
    assert fresh.audio_mode == :dual
    assert fresh.embedded_subtitle_mode == :require
    assert fresh.subtitle_languages == ["fr"]
    assert fresh.preferred_release_groups == ["subsplease"]
    assert fresh.blocked_release_groups == ["badgroup"]
    assert fresh.group_fallback_delay == 21_600

    view
    |> form("#series-profile-form", %{"media_profile" => "standard"})
    |> render_change()

    refute has_element?(view, "#anime-preferences-form")

    view
    |> form("#series-profile-form", %{"media_profile" => "anime"})
    |> render_change()

    assert has_element?(
             view,
             "#anime_preferences_audio_mode option[value='dual'][selected]"
           )

    assert has_element?(
             view,
             "#anime_preferences_preferred_release_groups[value='subsplease']"
           )

    assert has_element?(view, "#anime_preferences_group_fallback_delay_hours[value='6']")
  end

  test "series Anime preference errors are inline, retain input, and persist nothing", %{
    conn: conn
  } do
    series =
      series_fixture(%{
        media_profile: :anime,
        original_language: "ja",
        preferred_language: "original"
      })

    {:ok, view, _} = live_series(conn, series)

    view
    |> form(
      "#anime-preferences-form",
      anime_preferences: anime_preferences_params(%{"audio_mode" => "dual"})
    )
    |> render_submit()

    assert has_element?(view, "#anime_preferences_audio_mode-error")
    assert has_element?(view, "#anime_preferences_audio_mode option[value='dual'][selected]")

    view
    |> form(
      "#anime-preferences-form",
      anime_preferences:
        anime_preferences_params(%{
          "audio_mode" => "inherit",
          "group_fallback_delay_hours" => "-1"
        })
    )
    |> render_submit()

    assert has_element?(view, "#anime_preferences_group_fallback_delay_hours-error")
    assert has_element?(view, "#anime_preferences_group_fallback_delay_hours[value='-1']")

    view
    |> form(
      "#anime-preferences-form",
      anime_preferences:
        anime_preferences_params(%{
          "audio_mode" => "inherit",
          "subtitle_languages" => ""
        })
    )
    |> render_submit()

    assert has_element?(view, "#anime_preferences_subtitle_languages-error")
    assert has_element?(view, "#anime_preferences_subtitle_languages[value='']")

    fresh = Repo.reload!(series)
    assert fresh.audio_mode == nil
    assert fresh.embedded_subtitle_mode == nil
    assert fresh.subtitle_languages == nil
    assert fresh.group_fallback_delay == nil
  end

  test "series list controls can return to inherited non-empty Anime defaults", %{conn: conn} do
    put_nonempty_anime_defaults!()

    series =
      series_fixture(%{
        media_profile: :anime,
        original_language: "ja",
        preferred_language: "french"
      })
      |> Series.anime_preferences_changeset(%{
        subtitle_languages: ["en"],
        preferred_release_groups: ["old"],
        blocked_release_groups: ["old-blocked"]
      })
      |> Repo.update!()

    {:ok, view, _} = live_series(conn, series)

    view
    |> form(
      "#anime-preferences-form",
      anime_preferences:
        anime_preferences_params(%{
          "audio_mode" => "inherit",
          "embedded_subtitle_mode" => "inherit",
          "subtitle_languages_mode" => "inherit",
          "preferred_release_groups_mode" => "inherit",
          "blocked_release_groups_mode" => "inherit",
          "group_fallback_delay_mode" => "inherit"
        })
    )
    |> render_submit()

    fresh = Repo.reload!(series)
    assert fresh.subtitle_languages == nil
    assert fresh.preferred_release_groups == nil
    assert fresh.blocked_release_groups == nil
    html = render(view)
    assert html =~ "fr, en"
    assert html =~ "subsplease"
    assert html =~ "badgroup"
  end

  test "series dual audio without original metadata is field-invalid with explanatory help", %{
    conn: conn
  } do
    series =
      series_fixture(%{
        media_profile: :anime,
        original_language: nil,
        preferred_language: "french"
      })

    {:ok, view, _} = live_series(conn, series)

    view
    |> form(
      "#anime-preferences-form",
      anime_preferences: anime_preferences_params(%{"embedded_subtitle_mode" => "prefer"})
    )
    |> render_submit()

    assert has_element?(view, "#anime_preferences_audio_mode-error")
    assert has_element?(view, "#anime-dual-language-help")
    assert render(view) =~ "Dual audio requires known original-language metadata and a dub target"
    assert Repo.reload!(series).audio_mode == nil
  end

  test "series identity events tolerate forged profiles and aliases", %{conn: conn} do
    series = create_series(6_901)
    other = series_fixture()
    {:ok, other_alias} = Catalog.save_manual_alias(other, %{title: "Other series"})
    {:ok, view, _} = live_series(conn, series)

    render_hook(view, "set_media_profile", %{"media_profile" => "forged"})
    render_hook(view, "edit_alias", %{"id" => "not-an-id"})
    render_hook(view, "delete_alias", %{"id" => other_alias.id})

    assert Repo.reload(series).media_profile == :auto
    assert Repo.reload(other_alias).title == "Other series"
  end

  test "series episodes show sourced classification and ordered coordinates", %{conn: conn} do
    series = series_fixture()
    season = season_fixture(series, season_number: 1)

    episode =
      episode_fixture(season,
        episode_number: 1,
        classification: :story_special,
        classification_source: "manual",
        classification_label: "OVA"
      )

    earlier_member = episode_fixture(season, episode_number: 2)

    {:ok, _} =
      Catalog.put_episode_coordinate(
        series,
        %{
          source: "tmdb",
          scheme: "absolute",
          namespace: "absolute-group",
          canonical_value: "25",
          precedence: :curated
        },
        [earlier_member.id, episode.id]
      )

    {:ok, _} =
      Catalog.put_episode_coordinate(
        series,
        %{
          source: "manual",
          scheme: "scene",
          namespace: "manual",
          canonical_value: "26",
          precedence: :manual
        },
        [episode.id]
      )

    {:ok, view, _} = live_series(conn, series)

    assert has_element?(view, "#episode-#{episode.id}", "S01E01")

    assert has_element?(
             view,
             "#episode-#{episode.id} [data-coordinate='absolute:25']",
             "Absolute 25"
           )

    assert has_element?(view, "#episode-#{episode.id} [data-coordinate='scene:26']", "Scene 26")

    assert has_element?(
             view,
             "#episode-#{episode.id} [data-classification='story_special']",
             "Story special"
           )

    assert has_element?(view, "#episode-#{episode.id}", "OVA")

    coordinates =
      view
      |> element("#episode-#{episode.id}")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-coordinate]")
      |> LazyHTML.attribute("data-coordinate")

    assert coordinates == ["scene:26", "absolute:25"]
  end

  test "renders the page under the shared header", %{conn: conn} do
    series = create_series(799)
    {:ok, _lv, html} = live_series(conn, series)
    assert html =~ "Test Show"
    refute html =~ ~s(<h1 class="text-2xl font-semibold">)
  end

  test "held grabs show the Needs mapping badge and link to Activity", %{conn: conn} do
    series = create_series(798)
    episode = first_episode(series.id)

    grab =
      Repo.insert!(%Grab{
        download_id: "series-held-mapping",
        download_protocol: :torrent,
        mapping_snapshot: %{"version" => 2, "reserved_episode_ids" => [episode.id]},
        mapping_status: :needs_mapping,
        mapping_issue: %{"version" => 1, "reason" => "unresolved_file"}
      })

    episode |> Ecto.Changeset.change(grab_id: grab.id) |> Repo.update!()

    {:ok, view, _html} = live_series(conn, series)

    assert has_element?(view, "#series-mapping-grab-#{grab.id}", "Needs mapping")

    assert has_element?(
             view,
             ~s|#series-mapping-grab-#{grab.id} a[href="/activity"]|,
             "View in Activity"
           )
  end

  test "refreshes descriptive metadata when reopening an enriched series", %{conn: conn} do
    series =
      Repo.insert!(%Cinder.Catalog.Series{
        tmdb_id: 8_001,
        title: "S",
        year: 2020,
        overview: "Old overview",
        vote_average: 1.0
      })

    stub(Cinder.Catalog.TMDBMock, :get_series, fn 8_001 ->
      {:ok, %{base_series_info(8_001) | overview: "A show about things.", vote_average: 7.7}}
    end)

    {:ok, lv, initial_html} = live_series(conn, series, false)

    assert initial_html =~ "Old overview"
    assert render_async(lv) =~ "A show about things"
    render(lv)
  end

  test "renders the season/episode tree", %{conn: conn} do
    series = create_series(700)
    {:ok, _lv, html} = live_series(conn, series)

    assert html =~ "Test Show"
    assert html =~ "Season 1"
    assert html =~ "Pilot"
    assert html =~ "Two"
  end

  test "renders seasons collapsed by default", %{conn: conn} do
    series = create_series(701)
    {:ok, lv, _html} = live_series(conn, series)

    assert has_element?(lv, "details > summary", "Season 1")
    refute has_element?(lv, "details[open]")
  end

  test "shows audio + subtitle badges on a filed episode", %{conn: conn} do
    series = Repo.insert!(%Cinder.Catalog.Series{tmdb_id: 8200, title: "S", year: 2010})

    season =
      Repo.insert!(%Cinder.Catalog.Season{
        series_id: series.id,
        season_number: 1,
        monitored: true
      })

    Repo.insert!(%Cinder.Catalog.Episode{
      season_id: season.id,
      tmdb_episode_id: 8201,
      episode_number: 1,
      title: "Ep1",
      monitored: true,
      file_path: "/tmp/cinder-test-tv-library/S (2010)/Season 01/S (2010) - S01E01.mkv",
      imported_audio_languages: ["en", "fr"],
      imported_embedded_subtitles: ["en"],
      imported_sidecar_subtitles: ["fr"]
    })

    {:ok, _lv, html} = live_series(conn, series)
    assert html =~ "audio en"
    assert html =~ "audio fr"
    assert html =~ "subtitle en"
    assert html =~ "subtitle fr"
  end

  test "shows subtitle badges on a filed episode with empty/untagged audio", %{conn: conn} do
    series = Repo.insert!(%Cinder.Catalog.Series{tmdb_id: 8204, title: "S", year: 2010})

    season =
      Repo.insert!(%Cinder.Catalog.Season{
        series_id: series.id,
        season_number: 1,
        monitored: true
      })

    Repo.insert!(%Cinder.Catalog.Episode{
      season_id: season.id,
      tmdb_episode_id: 8205,
      episode_number: 1,
      title: "Ep1",
      monitored: true,
      file_path: "/tmp/cinder-test-tv-library/S (2010)/Season 01/S (2010) - S01E01.mkv",
      imported_audio_languages: [],
      imported_embedded_subtitles: ["en"]
    })

    {:ok, _lv, html} = live_series(conn, series)
    refute html =~ ~s(aria-label="audio)
    assert html =~ "subtitle en"
  end

  test "no audio/subtitle badges on a filed episode with no media info", %{conn: conn} do
    series = Repo.insert!(%Cinder.Catalog.Series{tmdb_id: 8202, title: "S", year: 2010})

    season =
      Repo.insert!(%Cinder.Catalog.Season{
        series_id: series.id,
        season_number: 1,
        monitored: true
      })

    Repo.insert!(%Cinder.Catalog.Episode{
      season_id: season.id,
      tmdb_episode_id: 8203,
      episode_number: 1,
      title: "Ep1",
      monitored: true,
      file_path: "/tmp/cinder-test-tv-library/S (2010)/Season 01/S (2010) - S01E01.mkv"
    })

    {:ok, _lv, html} = live_series(conn, series)
    refute html =~ ~s(aria-label="audio)
    refute html =~ ~s(aria-label="subtitle)
  end

  test "renders the series descriptive metadata block", %{conn: conn} do
    series = create_series(720)
    {:ok, _lv, html} = live_series(conn, series)

    assert html =~ "A test show overview."
    assert html =~ "Drama"
    assert html =~ "8.2"
  end

  test "toggling an episode flips its monitored flag in the DB", %{conn: conn} do
    series = create_series(701)
    ep = first_episode(series.id)
    refute ep.monitored

    {:ok, lv, _html} = live_series(conn, series)
    lv |> element(~s|input[phx-value-id="#{ep.id}"]|) |> render_click()

    assert Repo.reload(ep).monitored
  end

  test "the season bulk control monitors every episode", %{conn: conn} do
    series = create_series(702)
    season = first_season(series.id)
    refute season.monitored

    {:ok, lv, _html} = live_series(conn, series)

    lv
    |> element(~s|button[phx-click="toggle_season"][phx-value-id="#{season.id}"]|)
    |> render_click()

    eps = Catalog.get_series_with_tree(series.id).seasons |> hd() |> Map.fetch!(:episodes)
    assert Enum.all?(eps, & &1.monitored)
  end

  test "a missing series redirects to Library (/library)", %{conn: conn} do
    assert {:error, {kind, %{to: "/library"}}} = live(conn, ~p"/series/999999")
    assert kind in [:redirect, :live_redirect]
  end

  test "a non-integer id redirects to Library (/library)", %{conn: conn} do
    assert {:error, {kind, %{to: "/library"}}} = live(conn, ~p"/series/not-a-number")
    assert kind in [:redirect, :live_redirect]
  end

  test "a malformed toggle event does not crash the LiveView", %{conn: conn} do
    series = create_series(703)
    {:ok, lv, _html} = live_series(conn, series)
    render_hook(lv, "toggle_episode", %{"id" => "not-an-int"})
    assert render(lv) =~ "Test Show"
  end

  test "a series that vanishes out-of-band redirects on the next reload", %{conn: conn} do
    series = create_series(705)
    {:ok, lv, _html} = live_series(conn, series)

    # Delete the tree (cascades), then a series broadcast forces a reload that finds nothing.
    Repo.delete!(series)
    Phoenix.PubSub.broadcast(Cinder.PubSub, "series", {:series_updated, series.id})

    assert_redirect(lv, "/library")
  end

  test "a non-admin cannot reach the detail page", %{conn: conn} do
    series = create_series(704)
    user = user_fixture()
    conn = log_in_user(conn, user)
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/series/#{series.id}")
    # ponytail: the admin-gate redirect goes to "/" (UserAuth), not "/library"
  end

  test "redirects to Library (/library) when the open series is deleted", %{conn: conn} do
    series = Repo.insert!(%Cinder.Catalog.Series{tmdb_id: 7001, title: "Detail Show"})

    {:ok, lv, _html} = live_series(conn, series)

    Cinder.Catalog.broadcast_series_deleted(series.id)
    assert_redirect(lv, ~p"/library")
  end

  test "ignores a {:series_deleted, id} for a different series", %{conn: conn} do
    series = Repo.insert!(%Cinder.Catalog.Series{tmdb_id: 7002, title: "Stay Show"})

    {:ok, lv, _html} = live_series(conn, series)
    Cinder.Catalog.broadcast_series_deleted(series.id + 999)
    assert render(lv) =~ "Stay Show"
  end

  test "admin edits the series title", %{conn: conn} do
    series = create_series(710)
    {:ok, lv, _html} = live_series(conn, series)

    lv |> element(~s|button[phx-click="edit_series"]|) |> render_click()

    lv
    |> form("#series-form", %{"series" => %{"title" => "Renamed", "year" => "2021"}})
    |> render_submit()

    assert Repo.get!(Cinder.Catalog.Series, series.id).title == "Renamed"
    render(lv)
  end

  test "admin cancels the series: grabs reaped, episodes unmonitored", %{conn: conn} do
    series = create_series(711)
    ep = first_episode(series.id)
    # Monitor it + give it an active grab.
    {:ok, _} = Catalog.set_episode_monitored(ep, true)
    {:ok, _grab} = Catalog.create_grab("H-711", :torrent, [ep.id])

    expect(Cinder.Download.ClientMock, :remove, fn "H-711", _opts -> :ok end)

    {:ok, lv, _html} = live_series(conn, series)
    lv |> element(~s|button[phx-click="ask_cancel_series"]|) |> render_click()
    lv |> element(~s|button[phx-click="confirm_cancel_series"]|) |> render_click()

    assert Repo.all(Cinder.Catalog.Grab) == []
    assert Repo.reload(ep).monitored == false
  end

  test "admin deletes the series and is redirected to Library (/library)", %{conn: conn} do
    series = create_series(712)
    {:ok, lv, _html} = live_series(conn, series)

    lv |> element(~s|button[phx-click="ask_delete_series"]|) |> render_click()
    lv |> element(~s|button[phx-click="confirm_delete_series"]|) |> render_click()

    assert Repo.get(Cinder.Catalog.Series, series.id) == nil
    assert_redirect(lv, "/library")
  end

  test "deleting an episode file unlinks it and clears file_path (stays monitored)", %{
    conn: conn
  } do
    %{series: series, episode: ep} =
      series_with_episode_file_fixture(
        "/tmp/cinder-test-tv-library/S (2010)/Season 01/S (2010) - S01E01.mkv"
      )

    expect(Cinder.Library.FilesystemMock, :rm, fn _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :rmdir, fn _ -> {:error, :enotempty} end)

    {:ok, lv, _html} = live_series(conn, series)

    lv
    |> element("button[phx-click=ask_delete_episode_file][phx-value-id='#{ep.id}']")
    |> render_click()

    lv
    |> element("button[phx-click=confirm_delete_episode_file][phx-value-id='#{ep.id}']")
    |> render_click()

    reloaded = Cinder.Repo.get(Cinder.Catalog.Episode, ep.id)
    assert is_nil(reloaded.file_path)
    assert reloaded.monitored == true
  end

  test "deleting a season's files clears every episode file", %{conn: conn} do
    %{series: series, season: season} =
      season_with_files_fixture([
        "/tmp/cinder-test-tv-library/S (2010)/Season 01/S (2010) - S01E01.mkv"
      ])

    expect(Cinder.Library.FilesystemMock, :rm, fn _ -> :ok end)
    stub(Cinder.Library.FilesystemMock, :rmdir, fn _ -> {:error, :enotempty} end)

    {:ok, lv, _html} = live_series(conn, series)

    lv
    |> element("button[phx-click=ask_delete_season_files][phx-value-id='#{season.id}']")
    |> render_click()

    lv
    |> element("button[phx-click=confirm_delete_season_files][phx-value-id='#{season.id}']")
    |> render_click()

    assert Cinder.Catalog.get_series_with_tree(series.id).seasons
           |> Enum.flat_map(& &1.episodes)
           |> Enum.all?(&is_nil(&1.file_path))
  end

  test "Search all missing re-queues the season's wanted episodes", %{conn: conn} do
    series = series_with_wanted_episode(search_attempts: 9)

    {:ok, lv, _html} = live_series(conn, series)
    lv |> element("button", "Search all missing") |> render_click()

    assert [ep] = Catalog.wanted_episodes()
    assert ep.search_attempts == 0
  end

  test "the per-episode Search re-queues a single wanted episode", %{conn: conn} do
    series = series_with_wanted_episode(search_attempts: 7)
    [ep] = Catalog.wanted_episodes()

    {:ok, lv, _html} = live_series(conn, series)

    lv
    |> element("button[phx-click=search_episode][phx-value-id='#{ep.id}']")
    |> render_click()

    assert [requeued] = Catalog.wanted_episodes()
    assert requeued.search_attempts == 0
  end

  # An unmonitored episode is excluded from wanted_episodes/0, so a Search button on it
  # would be a no-op dressed as a confirmation. Gate it on monitored, like the season control.
  test "the per-episode Search button is gated on monitored", %{conn: conn} do
    series = series_with_wanted_episode(search_attempts: 0)
    [monitored] = Catalog.wanted_episodes()
    season = first_season(series.id)

    unmonitored =
      Repo.insert!(%Cinder.Catalog.Episode{
        season_id: season.id,
        tmdb_episode_id: 9102,
        episode_number: 2,
        title: "Two",
        monitored: false,
        air_date: Date.add(Date.utc_today(), -10)
      })

    {:ok, lv, _html} = live_series(conn, series)

    assert has_element?(lv, "button[phx-click=search_episode][phx-value-id='#{monitored.id}']")
    refute has_element?(lv, "button[phx-click=search_episode][phx-value-id='#{unmonitored.id}']")
  end

  test "a malformed search_episode event does not crash the LiveView", %{conn: conn} do
    series = series_with_wanted_episode(search_attempts: 0)
    {:ok, lv, _html} = live_series(conn, series)
    render_hook(lv, "search_episode", %{"id" => "not-an-int"})
    assert render(lv) =~ "Test Show"
  end

  # FIX 2: the Search affordance must mirror Catalog.wanted_episodes_query/0 — a monitored,
  # file-less, grab-less episode the sweep would NOT grab (not yet aired, or undated) must not
  # show a "Search" button that only flashes "Searching…" and never grabs.
  test "the per-episode Search button respects the sweep's air-date gate", %{conn: conn} do
    series = Repo.insert!(%Cinder.Catalog.Series{tmdb_id: 9301, tvdb_id: 93, title: "Test Show"})

    season =
      Repo.insert!(%Cinder.Catalog.Season{
        series_id: series.id,
        season_number: 1,
        monitored: true
      })

    aired = wanted_ep(season, 1, air_date: Date.add(Date.utc_today(), -1))
    future = wanted_ep(season, 2, air_date: Date.add(Date.utc_today(), 7))
    undated = wanted_ep(season, 3, air_date: nil)

    {:ok, lv, _html} = live_series(conn, series)

    assert has_element?(lv, "button[phx-click=search_episode][phx-value-id='#{aired.id}']")
    refute has_element?(lv, "button[phx-click=search_episode][phx-value-id='#{future.id}']")
    refute has_element?(lv, "button[phx-click=search_episode][phx-value-id='#{undated.id}']")
  end

  test "Search is limited to monitored Anime story specials and recaps", %{conn: conn} do
    anime =
      Repo.insert!(%Cinder.Catalog.Series{
        tmdb_id: 9302,
        tvdb_id: 94,
        title: "Anime",
        media_profile: :anime
      })

    specials =
      Repo.insert!(%Cinder.Catalog.Season{
        series_id: anime.id,
        season_number: 0,
        monitored: true
      })

    story =
      wanted_ep(specials, 1,
        air_date: Date.add(Date.utc_today(), -10),
        classification: :story_special
      )

    episode_zero =
      wanted_ep(specials, 0,
        air_date: Date.add(Date.utc_today(), -10),
        classification: :story_special
      )

    recap =
      wanted_ep(specials, 2,
        air_date: Date.add(Date.utc_today(), -10),
        classification: :recap
      )

    extra =
      wanted_ep(specials, 3,
        air_date: Date.add(Date.utc_today(), -10),
        classification: :extra
      )

    {:ok, lv, _html} = live_series(conn, anime)
    assert has_element?(lv, "button[phx-click=search_episode][phx-value-id='#{story.id}']")
    assert has_element?(lv, "button[phx-click=search_episode][phx-value-id='#{episode_zero.id}']")
    assert has_element?(lv, "button[phx-click=search_episode][phx-value-id='#{recap.id}']")
    refute has_element?(lv, "button[phx-click=search_episode][phx-value-id='#{extra.id}']")

    standard =
      Repo.insert!(%Cinder.Catalog.Series{
        tmdb_id: 9303,
        tvdb_id: 95,
        title: "Standard",
        media_profile: :standard
      })

    standard_specials =
      Repo.insert!(%Cinder.Catalog.Season{
        series_id: standard.id,
        season_number: 0,
        monitored: true
      })

    standard_story =
      wanted_ep(standard_specials, 1,
        air_date: Date.add(Date.utc_today(), -10),
        classification: :story_special
      )

    {:ok, standard_lv, _html} = live_series(conn, standard)

    refute has_element?(
             standard_lv,
             "button[phx-click=search_episode][phx-value-id='#{standard_story.id}']"
           )
  end

  test "a stale Search click is re-authorized against the current episode", %{conn: conn} do
    series = series_with_wanted_episode(search_attempts: 7)
    [episode] = Catalog.wanted_episodes()
    {:ok, lv, _html} = live_series(conn, series)

    episode
    |> Ecto.Changeset.change(monitored: false)
    |> Repo.update!()

    lv
    |> element("button[phx-click=search_episode][phx-value-id='#{episode.id}']")
    |> render_click()

    assert Repo.reload!(episode).search_attempts == 7
  end

  # FIX 1: "Find a better match" is only offered for a season with wanted episodes. An empty
  # indexer result then reads as "No releases found", and a fully-present season (TV replace is
  # deferred) is never offered manual search at all.
  test "Find a better match is offered only for a season with wanted episodes", %{conn: conn} do
    wanted = series_with_wanted_episode(search_attempts: 0)
    {:ok, lv, _html} = live_series(conn, wanted)
    assert has_element?(lv, "button[phx-click=tv_manual_search]")

    %{series: present} =
      series_with_episode_file_fixture("/tmp/cinder-test-tv-library/S (2010)/S01E01.mkv")

    {:ok, lv2, _html} = live_series(conn, present)
    refute has_element?(lv2, "button[phx-click=tv_manual_search]")
  end

  test "Find a better match opens the TV panel; grabbing creates a grab over the wanted episode",
       %{conn: conn} do
    series = series_with_wanted_episode(search_attempts: 0)
    season = first_season(series.id)

    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 99, "Test Show", 1 ->
      {:ok,
       [%{title: "Test Show S01E01 1080p WEB-DL GRP", size: 2_000_000_000, download_url: "u"}]}
    end)

    stub(Cinder.Download.ClientMock, :add, fn _release, _opts -> {:ok, "hash-new"} end)
    stub(Cinder.Download.ClientMock, :find_by_operation_key, fn _key -> :not_found end)

    {:ok, lv, _html} = live_series(conn, series)

    lv |> element("button", "Find a better match") |> render_click()
    assert render_async(lv) =~ "Test Show S01E01"

    lv |> element("#ms-season-#{season.id} button", "Grab") |> render_click()

    assert render(lv) =~ "Grabbing the selected release"
    assert [grab] = Repo.all(Cinder.Catalog.Grab)
    assert grab.download_id == "hash-new"
  end

  # Insert a series→season→episode tree with one still-wanted episode (monitored, no file,
  # no grab, aired). `search_attempts` seeds the backoff counter the search controls zero.
  defp series_with_wanted_episode(opts) do
    attempts = Keyword.get(opts, :search_attempts, 0)
    series = Repo.insert!(%Cinder.Catalog.Series{tmdb_id: 9001, tvdb_id: 99, title: "Test Show"})

    season =
      Repo.insert!(%Cinder.Catalog.Season{
        series_id: series.id,
        season_number: 1,
        monitored: true
      })

    Repo.insert!(%Cinder.Catalog.Episode{
      season_id: season.id,
      tmdb_episode_id: 9101,
      episode_number: 1,
      title: "Pilot",
      monitored: true,
      air_date: Date.add(Date.utc_today(), -10),
      search_attempts: attempts
    })

    Repo.reload!(series)
  end

  # Insert one wanted-shaped episode (monitored, no file, no grab) with a chosen air_date.
  defp wanted_ep(season, number, opts) do
    Repo.insert!(
      struct(
        %Cinder.Catalog.Episode{
          season_id: season.id,
          tmdb_episode_id: season.id * 100 + number,
          episode_number: number,
          title: "Ep#{number}",
          monitored: true
        },
        Map.new(opts)
      )
    )
  end

  # Insert a series→season→episode tree with one episode that has a file_path.
  defp series_with_episode_file_fixture(file_path) do
    series = Repo.insert!(%Cinder.Catalog.Series{tmdb_id: 8001, title: "S", year: 2010})

    season =
      Repo.insert!(%Cinder.Catalog.Season{
        series_id: series.id,
        season_number: 1,
        monitored: true
      })

    episode =
      Repo.insert!(%Cinder.Catalog.Episode{
        season_id: season.id,
        tmdb_episode_id: 8001,
        episode_number: 1,
        title: "Ep1",
        monitored: true,
        file_path: file_path
      })

    %{series: series, season: season, episode: episode}
  end

  # Insert a series→season→episode tree where the given file_paths are assigned across episodes.
  defp season_with_files_fixture(file_paths) do
    series = Repo.insert!(%Cinder.Catalog.Series{tmdb_id: 8002, title: "S", year: 2010})

    season =
      Repo.insert!(%Cinder.Catalog.Season{
        series_id: series.id,
        season_number: 1,
        monitored: true
      })

    file_paths
    |> Enum.with_index(1)
    |> Enum.each(fn {fp, n} ->
      Repo.insert!(%Cinder.Catalog.Episode{
        season_id: season.id,
        tmdb_episode_id: 8100 + n,
        episode_number: n,
        title: "Ep#{n}",
        monitored: true,
        file_path: fp
      })
    end)

    %{series: Repo.reload!(series), season: Repo.reload!(season)}
  end
end
