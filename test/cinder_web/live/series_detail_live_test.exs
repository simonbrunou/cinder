defmodule CinderWeb.SeriesDetailLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import Cinder.AccountsFixtures
  import Cinder.CatalogFixtures

  alias Cinder.{Catalog, Repo}
  alias Cinder.Catalog.{Grab, TitleAlias}

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

    stub(Cinder.Catalog.TMDBMock, :get_episode_group, fn id ->
      {:ok, episode_group(id: id, name: "Stub group")}
    end)

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

  test "the Audio pick offers all four options and drives the Anime audio mode", %{conn: conn} do
    series = series_fixture(media_profile: :anime)
    {:ok, view, _} = live_series(conn, series)

    assert has_element?(
             view,
             "#series-detail-language-form option[value='dual']",
             "French + original"
           )

    view
    |> form("#series-detail-language-form", %{"preferred_language" => "dual"})
    |> render_change()

    assert Repo.reload(series).preferred_language == "dual"
    assert has_element?(view, "#series-detail-language-form option[value='dual'][selected]")
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

  test "picks an alternate-numbering group, previews it, and saves it without refetching",
       %{conn: conn} do
    series = series_fixture(media_profile: :anime, tvdb_id: 12_345)

    stub(Cinder.Catalog.TMDBMock, :get_episode_groups, fn _ ->
      {:ok, [episode_group(id: "seasons-group", group_count: 3, episode_count: 64)]}
    end)

    # expect(..., 1, ...) rather than stub: proves Save reuses the preview's already-fetched
    # detail (threaded through as opts[:detail]) instead of a second TMDB round trip.
    expect(Cinder.Catalog.TMDBMock, :get_episode_group, 1, fn "seasons-group" ->
      {:ok,
       episode_group(
         id: "seasons-group",
         entries: [%{tmdb_episode_id: 1, group_name: "Season 2", group_order: 2, order: 0}]
       )}
    end)

    {:ok, view, _html} = live_series(conn, series)
    view |> element("summary", "Alternate numbering") |> render_click()
    assert render_async(view) =~ "Seasons (Seasons, 3 groups, 64 episodes)"

    view
    |> form("#series-scene-numbering-form", %{"group_id" => "seasons-group"})
    |> render_change()

    assert render_async(view) =~ "Season 2"

    view
    |> form("#series-scene-numbering-form", %{"group_id" => "seasons-group"})
    |> render_submit()

    # The save runs off-process via start_async (mirrors the preview above); await it before
    # reading the row back.
    html = render_async(view)
    assert html =~ "Alternate numbering saved."
    assert Repo.reload(series).scene_numbering_group_id == "seasons-group"

    # R4 finding 1: the persisted value catching up with what THIS session already selected and
    # previewed (i.e. our own Save) must not blank the just-previewed mapping.
    assert html =~ "Season 2"
  end

  # R5 finding 2: refresh_identity's own-save-vs-external-change check compared the newly
  # persisted group against the operator's CURRENT selection — if the operator reselects a
  # different group while their own earlier Save is still in flight, that Save's own reload must
  # not clobber the newer, unsaved selection.
  test "an operator's later reselection survives their own earlier save landing",
       %{conn: conn} do
    series = series_fixture(media_profile: :anime, tvdb_id: 12_345)
    test_pid = self()

    stub(Cinder.Catalog.TMDBMock, :get_episode_groups, fn _ ->
      {:ok,
       [
         episode_group(id: "group-b", name: "Group B", group_count: 1, episode_count: 1),
         episode_group(id: "group-c", name: "Group C", group_count: 1, episode_count: 1)
       ]}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_episode_group, fn
      "group-b" ->
        # Blocks until released below, so the save's own group-detail fetch is still in flight
        # when the operator reselects "group-c" below — mirrors a slow save racing a reselection.
        send(test_pid, {:group_b_fetch_started, self()})

        receive do
          :continue -> :ok
        end

        {:ok,
         episode_group(
           id: "group-b",
           entries: [%{tmdb_episode_id: 1, group_name: "Season 1", group_order: 1, order: 0}]
         )}

      "group-c" ->
        {:ok,
         episode_group(
           id: "group-c",
           entries: [%{tmdb_episode_id: 1, group_name: "Season 9", group_order: 9, order: 0}]
         )}
    end)

    {:ok, view, _html} = live_series(conn, series)
    view |> element("summary", "Alternate numbering") |> render_click()
    render_async(view)

    # Submit Save for "group-b" directly, with no prior selection/preview — so
    # set_scene_numbering_group has no cached detail to reuse and fetches it fresh, which is the
    # fetch this test gates.
    view
    |> form("#series-scene-numbering-form", %{"group_id" => "group-b"})
    |> render_submit()

    assert_receive {:group_b_fetch_started, blocked_pid}

    # Before that save lands, the operator changes their mind and picks "group-c" instead.
    view
    |> form("#series-scene-numbering-form", %{"group_id" => "group-c"})
    |> render_change()

    send(blocked_pid, :continue)
    html = render_async(view)

    assert html =~ "Alternate numbering saved."
    assert Repo.reload(series).scene_numbering_group_id == "group-b"

    # The operator's in-progress "group-c" selection and its preview must win, not "group-b".
    assert has_element?(view, "#series-scene-numbering-form option[value='group-c'][selected]")
    assert html =~ "Season 9"
    refute html =~ "Season 1"
  end

  # FINDING 11: a non-anime page never renders the panel, so it never even has the chance to
  # fetch; an anime page defers the fetch until the operator actually opens it.
  test "the episode-group list is lazily loaded only once the Alternate numbering panel opens",
       %{conn: conn} do
    series = series_fixture(media_profile: :anime, tvdb_id: 12_345)

    stub(Cinder.Catalog.TMDBMock, :get_episode_groups, fn _ ->
      {:ok, [episode_group(id: "g", group_count: 1, episode_count: 2)]}
    end)

    {:ok, view, html} = live_series(conn, series)
    assert html =~ "Loading episode groups…"
    refute html =~ "Seasons (Seasons"

    view |> element("summary", "Alternate numbering") |> render_click()
    assert render_async(view) =~ "Seasons (Seasons, 1 groups, 2 episodes)"
  end

  # FINDING 1(a): a failed load must never silently render the "None" prompt as selected while
  # a group is actually saved — show an error + Retry instead of the select.
  test "a failed episode-group load shows an error with Retry, not a silently-cleared select",
       %{conn: conn} do
    series =
      series_fixture(media_profile: :anime, tvdb_id: 12_345)
      |> Ecto.Changeset.change(scene_numbering_group_id: "seasons-group")
      |> Repo.update!()

    stub(Cinder.Catalog.TMDBMock, :get_episode_groups, fn _ -> {:error, :timeout} end)

    {:ok, view, _html} = live_series(conn, series)
    view |> element("summary", "Alternate numbering") |> render_click()
    render_async(view)

    assert has_element?(view, "p", "Couldn't load episode groups from TMDB.")
    assert has_element?(view, "button", "Retry")
    refute has_element?(view, "#series-scene-numbering-form")
  end

  # R2 finding 5: the native <details> toggle and the summary's phx-click fire together on BOTH
  # open and close — closing the panel after a failed load (without clicking Retry) must not
  # refire the fetch, or every accidental close/reopen while TMDB is down issues its own call.
  test "closing the panel after a failed load does not refetch; Retry still does",
       %{conn: conn} do
    series = series_fixture(media_profile: :anime, tvdb_id: 12_345)
    test_pid = self()

    stub(Cinder.Catalog.TMDBMock, :get_episode_groups, fn _ ->
      send(test_pid, :episode_groups_fetch)
      {:error, :timeout}
    end)

    {:ok, view, _html} = live_series(conn, series)
    view |> element("summary", "Alternate numbering") |> render_click()
    render_async(view)
    assert_receive :episode_groups_fetch

    assert has_element?(view, "p", "Couldn't load episode groups from TMDB.")

    # Same event as the initial open (the server can't tell open from close) — must no-op now
    # that episode_groups is :error.
    view |> element("summary", "Alternate numbering") |> render_click()
    render(view)
    refute_receive :episode_groups_fetch, 100

    assert has_element?(view, "p", "Couldn't load episode groups from TMDB.")

    stub(Cinder.Catalog.TMDBMock, :get_episode_groups, fn _ ->
      send(test_pid, :episode_groups_fetch)
      {:ok, [episode_group(id: "g", group_count: 1, episode_count: 1)]}
    end)

    view |> element("button", "Retry") |> render_click()
    assert_receive :episode_groups_fetch
    assert render_async(view) =~ "Seasons (Seasons, 1 groups, 1 episodes)"
  end

  # FINDING 1(b): when the loaded list doesn't contain the saved id (a group deleted/renamed on
  # TMDB), the select must not silently fall back to "None" — it gets a flagged synthetic option.
  test "a saved group missing from the loaded list appears as a flagged synthetic option",
       %{conn: conn} do
    series =
      series_fixture(media_profile: :anime, tvdb_id: 12_345)
      |> Ecto.Changeset.change(scene_numbering_group_id: "vanished-group")
      |> Repo.update!()

    stub(Cinder.Catalog.TMDBMock, :get_episode_groups, fn _ -> {:ok, []} end)
    stub(Cinder.Catalog.TMDBMock, :get_episode_group, fn _ -> {:error, :not_found} end)

    {:ok, view, _html} = live_series(conn, series)
    view |> element("summary", "Alternate numbering") |> render_click()
    html = render_async(view)

    assert html =~ "vanished-group (unavailable on TMDB)"

    assert has_element?(
             view,
             "#series-scene-numbering-form option[value='vanished-group'][selected]"
           )
  end

  # FINDING 8: a series that already has a saved group shows the right selection but a blank
  # preview until this fires — auto-preview once the list (and thus the form) is ready.
  test "auto-previews the saved group once the episode-group list finishes loading",
       %{conn: conn} do
    series =
      series_fixture(media_profile: :anime, tvdb_id: 12_345)
      |> Ecto.Changeset.change(scene_numbering_group_id: "seasons-group")
      |> Repo.update!()

    stub(Cinder.Catalog.TMDBMock, :get_episode_groups, fn _ ->
      {:ok, [episode_group(id: "seasons-group", group_count: 1, episode_count: 1)]}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_episode_group, fn "seasons-group" ->
      {:ok,
       episode_group(
         id: "seasons-group",
         entries: [%{tmdb_episode_id: 900, group_name: "Season 3", group_order: 3, order: 0}]
       )}
    end)

    {:ok, view, _html} = live_series(conn, series)
    view |> element("summary", "Alternate numbering") |> render_click()

    assert render_async(view) =~ "Season 3"
  end

  # FINDING 9: a stale preview fetch (for a selection the operator has since moved on from) must
  # never land and repopulate the preview.
  test "a stale preview fetch is discarded once the operator has selected something else",
       %{conn: conn} do
    series = series_fixture(media_profile: :anime, tvdb_id: 12_345)

    stub(Cinder.Catalog.TMDBMock, :get_episode_groups, fn _ ->
      {:ok,
       [
         episode_group(id: "group-a", name: "Group A", group_count: 1, episode_count: 1),
         episode_group(id: "group-b", name: "Group B", group_count: 1, episode_count: 1)
       ]}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_episode_group, fn
      "group-a" ->
        # Slow enough to guarantee it lands after group-b's fast, no-delay fetch below.
        Process.sleep(50)

        {:ok,
         episode_group(
           id: "group-a",
           entries: [%{tmdb_episode_id: 501, group_name: "Season 1", group_order: 1, order: 0}]
         )}

      "group-b" ->
        {:ok,
         episode_group(
           id: "group-b",
           entries: [%{tmdb_episode_id: 502, group_name: "Season 2", group_order: 2, order: 0}]
         )}
    end)

    {:ok, view, _html} = live_series(conn, series)
    view |> element("summary", "Alternate numbering") |> render_click()
    render_async(view)

    view
    |> form("#series-scene-numbering-form", %{"group_id" => "group-a"})
    |> render_change()

    view
    |> form("#series-scene-numbering-form", %{"group_id" => "group-b"})
    |> render_change()

    html = render_async(view)
    assert html =~ "Season 2"
    refute html =~ "Season 1"
  end

  # R2 finding 6: a quick manual selection change must not just have its superseded result
  # discarded on arrival (the belt) — the in-flight fetch itself is canceled (the suspender), so
  # its TMDB round trip is never wasted in the first place.
  test "picking a different group cancels the still-in-flight fetch for the previous selection",
       %{conn: conn} do
    series = series_fixture(media_profile: :anime, tvdb_id: 12_345)
    test_pid = self()

    stub(Cinder.Catalog.TMDBMock, :get_episode_groups, fn _ ->
      {:ok,
       [
         episode_group(id: "group-a", name: "Group A", group_count: 1, episode_count: 1),
         episode_group(id: "group-b", name: "Group B", group_count: 1, episode_count: 1)
       ]}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_episode_group, fn
      "group-a" ->
        # Long enough that, uncanceled, it would still complete well after this test asserts.
        Process.sleep(50)
        send(test_pid, :group_a_fetch_completed)
        {:ok, episode_group(id: "group-a")}

      "group-b" ->
        {:ok, episode_group(id: "group-b")}
    end)

    {:ok, view, _html} = live_series(conn, series)
    view |> element("summary", "Alternate numbering") |> render_click()
    render_async(view)

    view
    |> form("#series-scene-numbering-form", %{"group_id" => "group-a"})
    |> render_change()

    view
    |> form("#series-scene-numbering-form", %{"group_id" => "group-b"})
    |> render_change()

    render_async(view)

    # If group-a's fetch had merely been left running (only discarded on arrival), it would
    # have sent this well within the wait below.
    refute_receive :group_a_fetch_completed, 200

    # R3 finding 4: clearing back to "None" must cancel an in-flight fetch too, not just picking
    # a different group.
    view
    |> form("#series-scene-numbering-form", %{"group_id" => "group-a"})
    |> render_change()

    view
    |> form("#series-scene-numbering-form", %{"group_id" => ""})
    |> render_change()

    refute_receive :group_a_fetch_completed, 200
  end

  # R2 finding 1(a): reload() fires on any {:series_updated} broadcast — another tab's monitor
  # toggle, the 12h refresher — and must not discard an operator's in-progress, unsaved
  # alternate-numbering selection while its preview is still on screen.
  test "a series_updated broadcast between selection and save leaves the selection and preview intact",
       %{conn: conn} do
    series = series_fixture(media_profile: :anime, tvdb_id: 12_345)
    season = season_fixture(series)
    episode = episode_fixture(season)

    stub(Cinder.Catalog.TMDBMock, :get_episode_groups, fn _ ->
      {:ok, [episode_group(id: "seasons-group", group_count: 1, episode_count: 1)]}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_episode_group, fn "seasons-group" ->
      {:ok,
       episode_group(
         id: "seasons-group",
         entries: [%{tmdb_episode_id: 1, group_name: "Season 2", group_order: 2, order: 0}]
       )}
    end)

    {:ok, view, _html} = live_series(conn, series)
    view |> element("summary", "Alternate numbering") |> render_click()
    render_async(view)

    view
    |> form("#series-scene-numbering-form", %{"group_id" => "seasons-group"})
    |> render_change()

    assert render_async(view) =~ "Season 2"

    # Simulates another tab toggling a monitor flag (or the 12h refresher landing): broadcasts
    # {:series_updated, series.id} without touching scene_numbering_group_id.
    {:ok, _} = Catalog.set_episode_monitored(episode, false)
    :sys.get_state(view.pid)

    html = render(view)
    assert html =~ "Season 2"

    assert has_element?(
             view,
             "#series-scene-numbering-form option[value='seasons-group'][selected]"
           )
  end

  # R2 finding 1(b): the mirror case — a reload where the persisted group genuinely changed (a
  # second writer, not just any broadcast) must still reset the form to the new persisted value.
  # R3 finding 1: it must also drop the OLD group's preview, not keep rendering it under the
  # newly-selected group.
  # R4 finding 3: with the group list already loaded, the new group's preview must be re-fetched
  # automatically rather than leaving the panel blank until manual re-selection.
  test "a reload where the persisted group genuinely changed resets the form, clears the stale preview, and re-fetches the new one",
       %{conn: conn} do
    series =
      series_fixture(media_profile: :anime, tvdb_id: 12_345)
      |> Ecto.Changeset.change(scene_numbering_group_id: "group-a")
      |> Repo.update!()

    stub(Cinder.Catalog.TMDBMock, :get_episode_groups, fn _ ->
      {:ok,
       [
         episode_group(id: "group-a", name: "Group A", group_count: 1, episode_count: 1),
         episode_group(id: "group-b", name: "Group B", group_count: 1, episode_count: 1)
       ]}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_episode_group, fn
      "group-a" ->
        {:ok,
         episode_group(
           id: "group-a",
           entries: [%{tmdb_episode_id: 1, group_name: "Season 1", group_order: 1, order: 0}]
         )}

      "group-b" ->
        {:ok,
         episode_group(
           id: "group-b",
           entries: [%{tmdb_episode_id: 1, group_name: "Season 5", group_order: 5, order: 0}]
         )}
    end)

    {:ok, view, _html} = live_series(conn, series)
    view |> element("summary", "Alternate numbering") |> render_click()

    # Auto-preview for the already-saved group fires once the list lands (FINDING 8).
    assert render_async(view) =~ "Season 1"
    assert has_element?(view, "#series-scene-numbering-form option[value='group-a'][selected]")

    series
    |> Ecto.Changeset.change(scene_numbering_group_id: "group-b")
    |> Repo.update!()

    Phoenix.PubSub.broadcast(Cinder.PubSub, "series", {:series_updated, series.id})
    html = render_async(view)

    assert has_element?(view, "#series-scene-numbering-form option[value='group-b'][selected]")
    refute has_element?(view, "#series-scene-numbering-form option[value='group-a'][selected]")
    refute html =~ "Season 1"
    assert html =~ "Season 5"
  end

  # R5 finding 1: the auto-refetch above was gated on the group list merely having loaded once
  # (true forever after), not on the panel actually being open — a closed panel shouldn't spend
  # a live TMDB call on a preview nobody's looking at.
  test "does not refetch a genuinely-changed group's preview while the panel is closed",
       %{conn: conn} do
    series =
      series_fixture(media_profile: :anime, tvdb_id: 12_345)
      |> Ecto.Changeset.change(scene_numbering_group_id: "group-a")
      |> Repo.update!()

    test_pid = self()

    stub(Cinder.Catalog.TMDBMock, :get_episode_groups, fn _ ->
      {:ok,
       [
         episode_group(id: "group-a", name: "Group A", group_count: 1, episode_count: 1),
         episode_group(id: "group-b", name: "Group B", group_count: 1, episode_count: 1)
       ]}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_episode_group, fn id ->
      send(test_pid, {:episode_group_fetch, id})

      {:ok,
       episode_group(
         id: id,
         entries: [%{tmdb_episode_id: 1, group_name: "Season 1", group_order: 1, order: 0}]
       )}
    end)

    {:ok, view, _html} = live_series(conn, series)

    # Open once: loads the list and auto-previews the already-saved group-a.
    view |> element("summary", "Alternate numbering") |> render_click()
    render_async(view)
    assert_receive {:episode_group_fetch, "group-a"}

    # Close it — the native <details> toggle and this phx-click fire together on both open and
    # close, so the server can't otherwise tell them apart.
    view |> element("summary", "Alternate numbering") |> render_click()
    render(view)

    # A second writer moves the persisted group on while the panel is closed.
    series
    |> Ecto.Changeset.change(scene_numbering_group_id: "group-b")
    |> Repo.update!()

    Phoenix.PubSub.broadcast(Cinder.PubSub, "series", {:series_updated, series.id})
    :sys.get_state(view.pid)

    refute_receive {:episode_group_fetch, "group-b"}, 100
  end

  # R5 finding 1 (reopen path): the round-4 guarantee that a genuine external change re-fetches
  # its preview must still hold once the operator comes back to look — the closed panel skipping
  # the fetch (above) must not mean it's skipped forever.
  test "reopening the panel after a closed-panel external change fires the deferred preview",
       %{conn: conn} do
    series =
      series_fixture(media_profile: :anime, tvdb_id: 12_345)
      |> Ecto.Changeset.change(scene_numbering_group_id: "group-a")
      |> Repo.update!()

    stub(Cinder.Catalog.TMDBMock, :get_episode_groups, fn _ ->
      {:ok,
       [
         episode_group(id: "group-a", name: "Group A", group_count: 1, episode_count: 1),
         episode_group(id: "group-b", name: "Group B", group_count: 1, episode_count: 1)
       ]}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_episode_group, fn
      "group-a" ->
        {:ok,
         episode_group(
           id: "group-a",
           entries: [%{tmdb_episode_id: 1, group_name: "Season 1", group_order: 1, order: 0}]
         )}

      "group-b" ->
        {:ok,
         episode_group(
           id: "group-b",
           entries: [%{tmdb_episode_id: 1, group_name: "Season 9", group_order: 9, order: 0}]
         )}
    end)

    {:ok, view, _html} = live_series(conn, series)

    view |> element("summary", "Alternate numbering") |> render_click()
    assert render_async(view) =~ "Season 1"

    # Close it.
    view |> element("summary", "Alternate numbering") |> render_click()
    render(view)

    # External change lands while closed (the test above proves this doesn't fetch yet).
    series
    |> Ecto.Changeset.change(scene_numbering_group_id: "group-b")
    |> Repo.update!()

    Phoenix.PubSub.broadcast(Cinder.PubSub, "series", {:series_updated, series.id})
    :sys.get_state(view.pid)

    # Reopening must catch up: the group list is already loaded and a group is saved, so the
    # preview fires now instead of the panel staying blank until a manual re-selection.
    view |> element("summary", "Alternate numbering") |> render_click()
    assert render_async(view) =~ "Season 9"
  end

  # R2 finding 10: Episode.codes_label must render a non-contiguous derived season (reachable
  # from a Story Arc-shaped group whose subgroup entry orders skip a slot) as every actual
  # episode number, never a fake smooth range that hides the gap.
  test "a gappy derived season renders every episode number, not a fake smooth range",
       %{conn: conn} do
    series = series_fixture(media_profile: :anime, tvdb_id: 12_345)
    season = season_fixture(series, season_number: 1)
    episode_fixture(season, episode_number: 1, tmdb_episode_id: 101)
    episode_fixture(season, episode_number: 2, tmdb_episode_id: 102)
    episode_fixture(season, episode_number: 3, tmdb_episode_id: 103)

    stub(Cinder.Catalog.TMDBMock, :get_episode_groups, fn _ ->
      {:ok,
       [
         episode_group(
           id: "arcs-group",
           type: 5,
           name: "Story Arcs",
           group_count: 1,
           episode_count: 3
         )
       ]}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_episode_group, fn "arcs-group" ->
      {:ok,
       episode_group(
         id: "arcs-group",
         type: 5,
         name: "Story Arcs",
         entries: [
           %{tmdb_episode_id: 101, group_name: "Season 1", group_order: 1, order: 0},
           %{tmdb_episode_id: 102, group_name: "Season 1", group_order: 1, order: 1},
           # order: 3 (not 2) leaves a gap at alt episode 3 — the alt numbering is order + 1.
           %{tmdb_episode_id: 103, group_name: "Season 1", group_order: 1, order: 3}
         ]
       )}
    end)

    {:ok, view, _html} = live_series(conn, series)
    view |> element("summary", "Alternate numbering") |> render_click()
    render_async(view)

    view
    |> form("#series-scene-numbering-form", %{"group_id" => "arcs-group"})
    |> render_change()

    html = render_async(view)

    assert html =~ "S01E01E02E04"
    refute html =~ "S01E01–E04"
  end

  # A household admin needs the absolute number (it's how anime releases are named) and an
  # actionable classification (a Special that is/isn't grabbable) — nothing else about how
  # either was derived belongs on the row, even for a legacy row still carrying old provenance.
  test "an Anime episode row shows the absolute number and classification, never provenance",
       %{conn: conn} do
    series = series_fixture(media_profile: :anime)
    specials = season_fixture(series, season_number: 0)

    episode =
      episode_fixture(specials,
        episode_number: 1,
        classification: :story_special,
        classification_source: "manual",
        classification_label: "OVA"
      )

    earlier_member = episode_fixture(specials, episode_number: 2)

    episode_coordinate_fixture(
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

    episode_coordinate_fixture(
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

    row = view |> element("#episode-#{episode.id}") |> render()

    assert row =~ "#25"
    assert row =~ "Story special"
    refute row =~ "26"
    refute row =~ "OVA"
    refute row =~ "manual"
    refute row =~ "Source"
  end

  test "the absolute-number annotation is withheld from a non-Anime-profiled series",
       %{conn: conn} do
    series = series_fixture(media_profile: :standard)
    season = season_fixture(series, season_number: 1)
    episode = episode_fixture(season, episode_number: 1)

    episode_coordinate_fixture(
      series,
      %{
        source: "tmdb",
        scheme: "absolute",
        namespace: "absolute-group",
        canonical_value: "25",
        precedence: :curated
      },
      [episode.id]
    )

    {:ok, view, _} = live_series(conn, series)

    refute has_element?(view, "#episode-#{episode.id}", "#25")
  end

  # A classification annotation only ever changes behavior for a Season 0 special (regular
  # episodes are never classified otherwise) — a regular Season 1 episode shows none of it.
  test "a regular episode carries no classification annotation", %{conn: conn} do
    series = series_fixture()
    season = season_fixture(series, season_number: 1)
    episode = episode_fixture(season, episode_number: 1)

    {:ok, view, _} = live_series(conn, series)

    refute has_element?(view, "#episode-#{episode.id}", "Regular")
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

  test "shows an Available badge on a filed episode, no Wanted badge on an unmonitored one",
       %{conn: conn} do
    series = Repo.insert!(%Cinder.Catalog.Series{tmdb_id: 8210, title: "S", year: 2010})

    season =
      Repo.insert!(%Cinder.Catalog.Season{
        series_id: series.id,
        season_number: 1,
        monitored: true
      })

    # Available: has a file.
    Repo.insert!(%Cinder.Catalog.Episode{
      season_id: season.id,
      tmdb_episode_id: 8211,
      episode_number: 1,
      title: "Ep1",
      monitored: true,
      air_date: ~D[2000-01-01],
      file_path: "/tmp/cinder-test-tv-library/S (2010)/Season 01/S (2010) - S01E01.mkv"
    })

    # Unmonitored, aired, missing (e.g. :future-strategy back-catalog) — must NOT read "Wanted".
    Repo.insert!(%Cinder.Catalog.Episode{
      season_id: season.id,
      tmdb_episode_id: 8212,
      episode_number: 2,
      title: "Ep2",
      monitored: false,
      air_date: ~D[2000-01-08]
    })

    {:ok, _lv, html} = live_series(conn, series)
    assert html =~ "Available"
    refute html =~ "Wanted"
    # Season header carries an available count (1 of 2 episodes filed) alongside monitored.
    assert html =~ "1/2 available"
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

  # Seasons render as native <details>; their open state used to live only in the browser DOM, so
  # any {:series_updated} reload (the refresher, a grab landing, another tab's toggle) stripped the
  # `open` attribute and snapped expanded seasons shut. The open set is now tracked server-side.
  test "an expanded season stays open across a series_updated reload", %{conn: conn} do
    series = create_series(704)
    season = first_season(series.id)
    episode = hd(season.episodes)

    {:ok, lv, _html} = live_series(conn, series)
    refute has_element?(lv, "details#season-#{season.id}[open]")

    lv |> element("details#season-#{season.id} summary") |> render_click()
    assert has_element?(lv, "details#season-#{season.id}[open]")

    # A background monitor change broadcasts {:series_updated, series.id} and triggers reload().
    {:ok, _} = Catalog.set_episode_monitored(episode, true)
    :sys.get_state(lv.pid)

    assert has_element?(lv, "details#season-#{season.id}[open]")
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
