defmodule CinderWeb.ActivityLiveTest do
  use CinderWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Mox

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Grab}
  alias Cinder.Download.Intent
  alias Cinder.Repo

  import Cinder.CatalogFixtures

  setup :register_and_log_in_admin
  # The panel's async indexer search runs in a spawned Task, and the LiveView in its own
  # process, so the mocks must be visible across processes — global mode (the module is async: false).
  setup :set_mox_global

  defp grab! do
    series =
      Repo.insert!(%Cinder.Catalog.Series{
        tmdb_id: System.unique_integer([:positive]),
        title: "Severance",
        monitor_strategy: :all
      })

    season = Repo.insert!(%Cinder.Catalog.Season{series_id: series.id, season_number: 1})

    episode =
      Repo.insert!(%Cinder.Catalog.Episode{
        season_id: season.id,
        episode_number: 1,
        monitored: true
      })

    {:ok, grab} = Catalog.create_grab("abc123", :torrent, [episode.id])
    grab
  end

  defp verification_grab! do
    grab = grab!()

    grab
    |> Ecto.Changeset.change(%{
      content_path: "/downloads/Severance.S01E01.mkv",
      download_attempts: 10,
      mapping_snapshot: %{"version" => 2, "reserved_episode_ids" => []},
      release_policy_snapshot: %{
        "version" => 1,
        "required_audio_languages" => ["ja"],
        "required_embedded_subtitle_languages" => [],
        "release_group" => "group",
        "release_title" => "[Group] Severance S01E01"
      },
      mapping_status: :verification_blocked,
      automatic_mapping_decisions: %{"version" => 1, "files" => []}
    })
    |> Repo.update!()
    |> Repo.preload(:episodes)
  end

  test "renders the movie pipeline and live-updates on transition", %{conn: conn} do
    movie = movie_fixture(%{title: "Dune", year: 2021})

    {:ok, lv, html} = live(conn, ~p"/activity")
    assert html =~ "Dune"
    assert html =~ "Movie pipeline"
    # Management moved to the detail page — the row links there.
    assert has_element?(lv, ~s|#movie-#{movie.id} a[href="/movies/#{movie.id}"]|)

    {:ok, movie} = Catalog.transition(movie, %{status: :downloading})
    assert render(lv) =~ "progress-info"

    # Reaching a terminal-done state drops the row off the live pipeline (it's in /library now).
    {:ok, _} = Catalog.transition(movie, %{status: :available})
    refute has_element?(lv, "#movie-#{movie.id}")
  end

  test "terminal-done movies are absent from the pipeline at mount", %{conn: conn} do
    available = movie_fixture(%{title: "Arrival", status: :available})
    pending = movie_fixture(%{title: "Tenet", status: :requested})

    {:ok, lv, _html} = live(conn, ~p"/activity")
    refute has_element?(lv, "#movie-#{available.id}")
    assert has_element?(lv, "#movie-#{pending.id}")
  end

  test "renders grabs and deletes one through the confirm step", %{conn: conn} do
    grab = grab!()

    # Deleting the grab must also remove the tracked client download — a bare row
    # delete leaves it running and colliding with the freed episodes' re-grab.
    expect(Cinder.Download.ClientMock, :remove, fn download_id, _opts ->
      assert download_id == grab.download_id
      :ok
    end)

    {:ok, lv, html} = live(conn, ~p"/activity")
    assert html =~ "Severance"
    assert html =~ "Downloads"

    lv |> element("#grab-#{grab.id} button", "Delete") |> render_click()
    lv |> element("#confirm-delete-grab-#{grab.id} button", "Delete") |> render_click()

    refute has_element?(lv, "#grab-#{grab.id}")
    assert Catalog.list_grabs() == []
  end

  test "renders movie and TV grab download progress", %{conn: conn} do
    movie = movie_fixture(%{status: :downloading})
    grab = grab!()

    metrics = %{download_progress: 0.42, download_speed: 1_500_000, download_eta: 90}
    {:ok, _} = Catalog.update_movie_download_metrics(movie, metrics)
    {:ok, _} = Catalog.update_grab_download_metrics(grab, metrics)

    {:ok, lv, _html} = live(conn, ~p"/activity")

    assert lv |> element("#movie-#{movie.id}") |> render() =~ "42%"
    assert lv |> element("#grab-#{grab.id}") |> render() =~ "42%"
  end

  test "held grabs show Needs mapping and link to the shared recovery route", %{conn: conn} do
    grab = grab!()

    held =
      grab
      |> Ecto.Changeset.change(%{
        mapping_snapshot: %{"version" => 2, "reserved_episode_ids" => []},
        mapping_status: :needs_mapping,
        automatic_mapping_decisions: %{"version" => 1, "files" => []}
      })
      |> Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/activity")

    assert has_element?(view, "#grab-#{held.id}", "Needs mapping")

    assert has_element?(
             view,
             ~s|#grab-#{held.id} a[href="/activity/grabs/#{held.id}/mapping"]|,
             "Review mapping"
           )

    assert has_element?(view, "#ask-cancel-mapping-grab-#{held.id}", "Cancel download")
    refute has_element?(view, "#grab-#{held.id} button", "Delete")
  end

  test "verification holds show retry and cancel without exposing the mapping editor", %{
    conn: conn
  } do
    held = verification_grab!()

    {:ok, view, _html} = live(conn, ~p"/activity")

    assert has_element?(view, "#grab-#{held.id}", "Needs verification")
    assert has_element?(view, "#retry-verification-grab-#{held.id}", "Retry verification")
    assert has_element?(view, "#cancel-verification-grab-#{held.id}", "Cancel download")

    refute has_element?(
             view,
             ~s|#grab-#{held.id} a[href="/activity/grabs/#{held.id}/mapping"]|
           )

    refute has_element?(view, "#grab-#{held.id}", "Review mapping")
    refute has_element?(view, "#grab-#{held.id} input")

    assert {:error, {kind, %{to: "/activity"}}} =
             live(conn, "/activity/grabs/#{held.id}/mapping")

    assert kind in [:redirect, :live_redirect]
  end

  test "retry verification resets only the hold and counter without service I/O", %{conn: conn} do
    held = verification_grab!()
    saved_media_info = Application.get_env(:cinder, :media_info)
    Application.put_env(:cinder, :media_info, Cinder.Library.MediaInfoMock)

    on_exit(fn ->
      if saved_media_info,
        do: Application.put_env(:cinder, :media_info, saved_media_info),
        else: Application.delete_env(:cinder, :media_info)
    end)

    calls = start_supervised!({Agent, fn -> %{filesystem: 0, media_info: 0, client: 0} end})

    stub(Cinder.Library.FilesystemMock, :dir?, fn _path ->
      Agent.update(calls, &Map.update!(&1, :filesystem, fn count -> count + 1 end))
      false
    end)

    stub(Cinder.Library.MediaInfoMock, :probe_policy, fn _path ->
      Agent.update(calls, &Map.update!(&1, :media_info, fn count -> count + 1 end))
      {:error, :unexpected}
    end)

    stub(Cinder.Download.ClientMock, :remove, fn _remote_id, _opts ->
      Agent.update(calls, &Map.update!(&1, :client, fn count -> count + 1 end))
      :ok
    end)

    {:ok, view, _html} = live(conn, ~p"/activity")
    view |> element("#retry-verification-grab-#{held.id}") |> render_click()

    assert %Grab{mapping_status: :resolved, download_attempts: 0} =
             retried =
             Repo.get!(Grab, held.id)

    assert retried.content_path == held.content_path
    assert retried.mapping_snapshot == held.mapping_snapshot
    assert retried.release_policy_snapshot == held.release_policy_snapshot
    assert Agent.get(calls, & &1) == %{filesystem: 0, media_info: 0, client: 0}
  end

  test "cancel verification keeps the existing durable cleanup fence", %{conn: conn} do
    held = verification_grab!()
    [episode] = held.episodes

    expect(Cinder.Download.ClientMock, :remove, fn remote_id, delete_files: true ->
      assert remote_id == held.download_id
      {:error, :client_down}
    end)

    {:ok, view, _html} = live(conn, ~p"/activity")
    view |> element("#cancel-verification-grab-#{held.id}") |> render_click()

    view
    |> element("#confirm-delete-grab-#{held.id} button", "Cancel download")
    |> render_click()

    refute Repo.get(Grab, held.id)
    assert Repo.get!(Episode, episode.id).grab_id == nil

    remote_id = held.download_id

    assert Repo.exists?(
             from i in Intent,
               where: i.remote_id == ^remote_id and i.status == :cleanup_pending
           )
  end

  test "a stale held confirmation cannot cancel a concurrently resumed grab", %{conn: conn} do
    grab = grab!() |> Repo.preload(:episodes)
    [episode] = grab.episodes

    decisions = %{
      "version" => 1,
      "files" => [
        %{
          "relative_path" => "Severance - 01.mkv",
          "size" => 10,
          "major_device" => 7,
          "inode" => 21,
          "mtime" => "2026-07-13T12:01:00",
          "parsed" => %{
            "coordinates" => [%{"scheme" => "absolute", "values" => ["1"]}],
            "role" => "main",
            "group" => nil
          },
          "episode_ids" => [episode.id],
          "source" => "automatic",
          "ignored" => false
        }
      ]
    }

    held =
      grab
      |> Ecto.Changeset.change(%{
        mapping_snapshot: %{"version" => 2, "reserved_episode_ids" => [episode.id]},
        mapping_status: :needs_mapping,
        automatic_mapping_decisions: decisions
      })
      |> Repo.update!()

    parent = self()

    stub(Cinder.Download.ClientMock, :remove, fn remote_id, opts ->
      send(parent, {:remote_remove, remote_id, opts})
      :ok
    end)

    {:ok, view, _html} = live(conn, ~p"/activity")
    view |> element("#ask-cancel-mapping-grab-#{held.id}") |> render_click()
    assert has_element?(view, "#confirm-cancel-mapping-grab-#{held.id}")

    assert {:ok, resumed} =
             Catalog.resume_grab_mapping(held, %{
               "files" => [
                 %{
                   "relative_path" => "Severance - 01.mkv",
                   "action" => "assign",
                   "episode_ids" => [episode.id]
                 }
               ],
               "target_episode_ids" => [episode.id],
               "monitor_episode_ids" => []
             })

    render_click(view, "confirm_cancel_mapping", %{"id" => to_string(held.id)})

    assert Repo.get!(Cinder.Catalog.Grab, held.id).mapping_status == :resolved
    assert Repo.get!(Cinder.Catalog.Episode, episode.id).grab_id == resumed.id
    assert Repo.aggregate(Cinder.Download.Intent, :count) == 0
    refute_received {:remote_remove, _, [delete_files: true]}
  end

  test "non-admins are redirected away from /activity", %{conn: _conn} do
    conn = build_conn() |> log_in_user(Cinder.AccountsFixtures.user_fixture())
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/activity")
  end

  test "/status and /grabs redirect to /activity", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/status")) == "/activity"
    assert redirected_to(get(conn, ~p"/grabs")) == "/activity"
  end
end
