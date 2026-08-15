defmodule CinderWeb.ActivityLiveTest do
  use CinderWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Mox

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Grab, GrabFile}
  alias Cinder.Download.Intent
  alias Cinder.Download.TvPoller
  alias Cinder.Library.ImportStage
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
      mapping_status: :verification_blocked
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
    {:ok, movie} = Catalog.transition(movie, %{status: :downloaded})
    {:ok, _} = Catalog.transition(movie, %{status: :available})
    refute has_element?(lv, "#movie-#{movie.id}")
  end

  test "a searching movie shows the attempt-count hint", %{conn: conn} do
    movie =
      %{title: "Dune", status: :searching}
      |> movie_fixture()
      |> Ecto.Changeset.change(search_attempts: 2)
      |> Repo.update!()

    {:ok, lv, _html} = live(conn, ~p"/activity")
    assert has_element?(lv, "#movie-#{movie.id}-hint", "Searching indexers (attempt 3)")
  end

  test "a parked movie explains why it is stuck", %{conn: conn} do
    movie = movie_fixture(%{title: "Solaris", status: :no_match})

    {:ok, lv, _html} = live(conn, ~p"/activity")
    assert has_element?(lv, "#movie-#{movie.id}-hint", "No release matched")
  end

  test "a parked movie surfaces the download client's preserved failure reason", %{conn: conn} do
    # The poller persists the client's reason (SABnzbd's paused state / fail_message) as
    # failure_reason; /activity shows it verbatim instead of the generic import-failed hint.
    movie =
      %{title: "Akira", status: :import_failed}
      |> movie_fixture()
      |> Ecto.Changeset.change(failure_reason: "Unpacking failed, write error or disk full?")
      |> Repo.update!()

    {:ok, lv, _html} = live(conn, ~p"/activity")

    assert has_element?(
             lv,
             "#movie-#{movie.id}-hint",
             "Unpacking failed, write error or disk full?"
           )
  end

  test "lists background sweeps with plain-language labels and their schedule", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/activity")

    assert has_element?(lv, "h2", "Background sweeps")

    assert has_element?(
             lv,
             "p",
             "These tasks retry failed searches, look for better releases, remove unneeded partial downloads, update series, back up the database, find missing subtitles, and sync Plex watchlists."
           )

    assert has_element?(lv, "#job-Refresher", "Series metadata refresh")
    assert has_element?(lv, "#job-Rehunter", "Try failed title searches again")
    assert has_element?(lv, "#job-UpgradeHunter", "Look for better-quality releases")
    assert has_element?(lv, "#job-Cleaner", "Remove unneeded partial downloads")
    assert has_element?(lv, "#job-Sweeper", "Find missing subtitles")
    # A registered sweep needs a translated label. Verified to fail (on this assertion) when the
    # job_label/1 clause is removed, i.e. when the raw module name renders instead.
    assert has_element?(lv, "#job-WatchlistSync", "Plex watchlist sync")

    for jargon <- [
          "Parked title rehunt",
          "Quality upgrade hunt",
          "Orphaned download cleanup",
          "Subtitle backfill"
        ] do
      refute has_element?(lv, "#activity-jobs", jargon)
    end

    # Each sweep shows a last-run/next-run line (its value depends on global run state).
    assert has_element?(lv, "#job-Refresher", "Last run:")
    assert has_element?(lv, "#job-Sweeper", "Next:")
  end

  test "the upgrade hunt shows its off state instead of a schedule", %{conn: conn} do
    # Shipped default (config.exs): the sweep is off, so it must not advertise a next run.
    {:ok, lv, _html} = live(conn, ~p"/activity")

    assert has_element?(lv, "#job-UpgradeHunter", "Turn it on in Settings.")
    refute has_element?(lv, "#job-UpgradeHunter", "Next:")

    saved = Application.get_env(:cinder, Cinder.Catalog.UpgradeHunter)
    on_exit(fn -> Application.put_env(:cinder, Cinder.Catalog.UpgradeHunter, saved) end)
    Application.put_env(:cinder, Cinder.Catalog.UpgradeHunter, enabled: true)

    {:ok, lv, _html} = live(conn, ~p"/activity")

    assert has_element?(lv, "#job-UpgradeHunter", "Next:")
    refute has_element?(lv, "#job-UpgradeHunter", "Turn it on in Settings.")
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

  test "a held grab shows Needs mapping, its reason, and Retry import/Discard actions", %{
    conn: conn
  } do
    grab = grab!()

    held =
      grab
      |> Ecto.Changeset.change(%{
        mapping_snapshot: %{"version" => 2, "reserved_episode_ids" => []},
        mapping_status: :needs_mapping,
        mapping_issue: %{
          "version" => 1,
          "reason" => "unresolved_file",
          "relative_paths" => ["Severance - 01.mkv"],
          "candidate_episode_ids" => []
        }
      })
      |> Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/activity")

    assert has_element?(view, "#grab-#{held.id}", "Needs mapping")
    assert has_element?(view, "#grab-#{held.id}-mapping-reason", "Severance - 01.mkv")
    assert has_element?(view, "#retry-mapping-grab-#{held.id}", "Retry import")
    assert has_element?(view, "#ask-cancel-mapping-grab-#{held.id}", "Discard")
    refute has_element?(view, "#grab-#{held.id} button", "Delete")
  end

  test "a standard residual grab shows explicit Fold, Part, and Hold actions with no selection",
       %{
         conn: conn
       } do
    grab = grab!()
    {:ok, grab} = Catalog.mark_grab_downloaded(grab, "/downloads/Severance")
    episode = Repo.get_by!(Episode, grab_id: grab.id)

    for {path, inode} <- [{"part-2.mkv", 11}, {"part-3.mkv", 12}] do
      Repo.insert!(%GrabFile{
        grab_id: grab.id,
        relative_path: path,
        size: 10,
        device: 1,
        inode: inode
      })
    end

    {:ok, view, _html} = live(conn, ~p"/activity")

    assert has_element?(view, "#grab-#{grab.id}", "Needs mapping")

    assert has_element?(
             view,
             "#grab-#{grab.id}-file-reason",
             "2 unmatched videos were kept in the download source for review."
           )

    refute has_element?(view, "#grab-#{grab.id}", "Retry import")
    refute has_element?(view, "#retry-mapping-grab-#{grab.id}")
    refute has_element?(view, "#ask-cancel-mapping-grab-#{grab.id}")

    for file <- Repo.all(from f in GrabFile, where: f.grab_id == ^grab.id) do
      assert has_element?(view, "#grab-file-#{file.id}", file.relative_path)
      assert has_element?(view, "#grab-file-#{file.id} button[value=fold]", "Fold")
      assert has_element?(view, "#grab-file-#{file.id} button[value=part]", "Keep as part")
      assert has_element?(view, "#grab-file-#{file.id} button", "Hold")
      assert has_element?(view, "#grab-file-#{file.id} button", "Discard")

      refute has_element?(
               view,
               "#grab-file-#{file.id}-episode option[value=\"#{episode.id}\"][selected]"
             )
    end

    first = Repo.one!(from f in GrabFile, where: f.grab_id == ^grab.id, order_by: f.id, limit: 1)
    view |> element("#grab-file-#{first.id} button", "Hold") |> render_click()

    assert Repo.get!(GrabFile, first.id).decision == nil
    assert Repo.get(Grab, grab.id)
    assert has_element?(view, "#grab-file-#{first.id}")
  end

  test "Discard resolves one residual file and Discard all decides the rest, closing the grab", %{
    conn: conn
  } do
    grab = grab!()
    {:ok, grab} = Catalog.mark_grab_downloaded(grab, "/downloads/Severance")
    episode = Repo.get_by!(Episode, grab_id: grab.id)

    for {path, inode} <- [{"part-2.mkv", 11}, {"part-3.mkv", 12}, {"part-4.mkv", 13}] do
      Repo.insert!(%GrabFile{
        grab_id: grab.id,
        relative_path: path,
        size: 10,
        device: 1,
        inode: inode
      })
    end

    first = Repo.one!(from f in GrabFile, where: f.grab_id == ^grab.id, order_by: f.id, limit: 1)

    {:ok, view, _html} = live(conn, ~p"/activity")

    # Discard is irreversible, so the first click only asks — nothing is decided yet.
    view |> element("#grab-file-#{first.id} button", "Discard") |> render_click()

    assert has_element?(view, "#confirm-discard-grab-file-#{first.id}")
    assert %GrabFile{decision: nil} = Repo.get!(GrabFile, first.id)

    view |> element("#confirm-discard-grab-file-#{first.id} button", "Discard") |> render_click()

    assert %GrabFile{decision: :discard, episode_id: nil, destination: nil, import_stage_id: nil} =
             Repo.get!(GrabFile, first.id)

    # One decision short of a close: the grab, its hold row, and the other files remain.
    assert Repo.get(Grab, grab.id)
    refute has_element?(view, "#grab-file-#{first.id}")
    assert has_element?(view, "#grab-#{grab.id}-file-reason")

    view |> element("#discard-grab-files-#{grab.id}") |> render_click()

    # Same for the bulk action: asking leaves every remaining row undecided — all of them, not
    # just one, or a bulk ask that decided some would slip through.
    assert has_element?(view, "#confirm-discard-grab-files-#{grab.id}")

    assert 2 ==
             Repo.aggregate(
               from(f in GrabFile, where: f.grab_id == ^grab.id and is_nil(f.decision)),
               :count
             )

    view
    |> element("#confirm-discard-grab-files-#{grab.id} button", "Discard all")
    |> render_click()

    # close_grab/1 rolls back while any row is still undecided, so a deleted grab is proof the
    # bulk click decided every remaining file — their rows cascade away with it.
    refute Repo.get(Grab, grab.id)
    refute Repo.exists?(from f in GrabFile, where: f.grab_id == ^grab.id)
    refute has_element?(view, "#grab-#{grab.id}")

    # Nothing was bound to the grab's own episode along the way.
    assert %Episode{file_path: nil, part_file_paths: []} = Repo.reload!(episode)
    refute Repo.exists?(ImportStage)
  end

  test "a forged id on any confirm-key event is ignored rather than crashing the view", %{
    conn: conn
  } do
    grab = grab!()
    {:ok, _grab} = Catalog.mark_grab_downloaded(grab, "/downloads/Severance")

    Repo.insert!(%GrabFile{
      grab_id: grab.id,
      relative_path: "part-2.mkv",
      size: 10,
      device: 1,
      inode: 11
    })

    {:ok, view, _html} = live(conn, ~p"/activity")

    # Every handler that builds a `confirming` key by interpolation must reject a non-binary id.
    # Without the guard the interpolation raises inside the clause body, and the catch-all can't
    # help because the clause has already matched — the LiveView dies and the tab reconnects.
    for event <- ~w(ask_cancel_mapping ask_discard_file ask_discard_files) do
      assert render_click(view, event, %{"id" => %{"forged" => true}})
      assert render_click(view, event, %{"id" => 7})
    end

    # Still alive, no confirmation opened on a forged key, and nothing decided at all.
    assert has_element?(view, "#grab-#{grab.id}")
    refute has_element?(view, "#confirm-cancel-mapping-grab-#{grab.id}")

    refute Repo.exists?(
             from f in GrabFile, where: f.grab_id == ^grab.id and not is_nil(f.decision)
           )
  end

  test "cancelling a Discard confirmation decides nothing", %{conn: conn} do
    grab = grab!()
    {:ok, grab} = Catalog.mark_grab_downloaded(grab, "/downloads/Severance")

    file =
      Repo.insert!(%GrabFile{
        grab_id: grab.id,
        relative_path: "part-2.mkv",
        size: 10,
        device: 1,
        inode: 11
      })

    {:ok, view, _html} = live(conn, ~p"/activity")

    view |> element("#grab-file-#{file.id} button", "Discard") |> render_click()
    assert has_element?(view, "#confirm-discard-grab-file-#{file.id}")

    view |> element("#confirm-discard-grab-file-#{file.id} button", "Cancel") |> render_click()

    refute has_element?(view, "#confirm-discard-grab-file-#{file.id}")
    assert %GrabFile{decision: nil} = Repo.get!(GrabFile, file.id)
    assert Repo.get(Grab, grab.id)
  end

  test "the no-eligible-episode fallback also asks before discarding", %{conn: conn} do
    grab = grab!()
    {:ok, grab} = Catalog.mark_grab_downloaded(grab, "/downloads/Severance")

    file =
      Repo.insert!(%GrabFile{
        grab_id: grab.id,
        relative_path: "part-2.mkv",
        size: 10,
        device: 1,
        inode: 11
      })

    # With no episode left to fold onto, this branch renders its own Discard button.
    Repo.delete_all(from e in Episode, where: e.grab_id == ^grab.id)

    {:ok, view, _html} = live(conn, ~p"/activity")

    assert render(view) =~ "No eligible TMDB episode remains"

    view |> element("#grab-file-#{file.id} button", "Discard") |> render_click()

    assert has_element?(view, "#confirm-discard-grab-file-#{file.id}")
    assert %GrabFile{decision: nil} = Repo.get!(GrabFile, file.id)

    view |> element("#confirm-discard-grab-file-#{file.id} button", "Discard") |> render_click()

    # It was the grab's only file, so deciding it closes the grab and cascades the row away —
    # close_grab/1 rolls back while anything is still undecided, so this is proof it was decided.
    refute Repo.get(Grab, grab.id)
    refute Repo.get(GrabFile, file.id)
  end

  test "a Discard confirmation whose row was decided meanwhile does not report a discard", %{
    conn: conn
  } do
    grab = grab!()
    {:ok, grab} = Catalog.mark_grab_downloaded(grab, "/downloads/Severance")

    for {path, inode} <- [{"part-2.mkv", 11}, {"part-3.mkv", 12}] do
      Repo.insert!(%GrabFile{
        grab_id: grab.id,
        relative_path: path,
        size: 10,
        device: 1,
        inode: inode
      })
    end

    first = Repo.one!(from f in GrabFile, where: f.grab_id == ^grab.id, order_by: f.id, limit: 1)

    {:ok, view, _html} = live(conn, ~p"/activity")

    view |> element("#grab-file-#{first.id} button", "Discard") |> render_click()
    assert has_element?(view, "#confirm-discard-grab-file-#{first.id}")

    # The confirmation sits open while the row is decided out from under it — another operator,
    # or the poller. The grab survives (a sibling file is still undecided), so the LiveView's
    # snapshot still offers this id and the handler really does dispatch on a decided row.
    assert {:ok, :decided, _} = TvPoller.discard_grab_file(first.id)

    html = render_click(view, "confirm_discard_file", %{"id" => to_string(first.id)})

    # It decided nothing, so it must not say it saved a decision.
    refute html =~ "File decision saved."
    assert html =~ "already decided"
    assert Repo.get(Grab, grab.id)
  end

  test "a Part staging failure stays on its row and leaves every write unresolved", %{conn: conn} do
    grab = grab!()
    {:ok, grab} = Catalog.mark_grab_downloaded(grab, "/downloads/Severance")
    episode = Repo.get_by!(Episode, grab_id: grab.id)
    {:ok, episode} = Catalog.transition_episode(episode, %{file_path: "/tv/Severance.S01E01.mkv"})

    file =
      Repo.insert!(%GrabFile{
        grab_id: grab.id,
        relative_path: "part-2.mkv",
        size: 10,
        device: 1,
        inode: 11
      })

    stub(Cinder.Library.FilesystemMock, :dir?, fn _path -> true end)

    stub(Cinder.Library.FilesystemMock, :lstat, fn _path ->
      {:ok, %File.Stat{size: 10, major_device: 1, inode: 11, type: :regular}}
    end)

    stub(Cinder.Library.FilesystemMock, :mkdir_p, fn _path -> {:error, :eacces} end)

    {:ok, view, _html} = live(conn, ~p"/activity")

    view
    |> element("#grab-file-#{file.id}-resolution-form")
    |> render_submit(%{
      "resolution" => %{
        "grab_file_id" => to_string(file.id),
        "episode_id" => to_string(episode.id),
        "decision" => "part"
      }
    })

    assert has_element?(
             view,
             "#grab-file-#{file.id}-error",
             "The file could not be resolved and remains held."
           )

    assert %GrabFile{decision: nil, destination: nil, import_stage_id: nil} =
             Repo.get!(GrabFile, file.id)

    assert Repo.reload!(episode).part_file_paths == []
    refute Repo.exists?(ImportStage)
  end

  test "Retry import releases a held grab back to resolved", %{conn: conn} do
    grab = grab!()

    held =
      grab
      |> Ecto.Changeset.change(%{
        mapping_snapshot: %{"version" => 2, "reserved_episode_ids" => []},
        mapping_status: :needs_mapping,
        mapping_issue: %{"version" => 1, "reason" => "unresolved_file"}
      })
      |> Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/activity")
    view |> element("#retry-mapping-grab-#{held.id}") |> render_click()

    assert Repo.get!(Grab, held.id).mapping_status == :resolved
    refute has_element?(view, "#retry-mapping-grab-#{held.id}")
  end

  test "Discard removes a held grab and frees its episode", %{conn: conn} do
    grab = grab!() |> Repo.preload(:episodes)
    [episode] = grab.episodes

    held =
      grab
      |> Ecto.Changeset.change(%{
        mapping_snapshot: %{"version" => 2, "reserved_episode_ids" => [episode.id]},
        mapping_status: :needs_mapping,
        mapping_issue: %{"version" => 1, "reason" => "unresolved_file"}
      })
      |> Repo.update!()

    expect(Cinder.Download.ClientMock, :remove, fn remote_id, delete_files: true ->
      assert remote_id == held.download_id
      :ok
    end)

    {:ok, view, _html} = live(conn, ~p"/activity")
    view |> element("#ask-cancel-mapping-grab-#{held.id}") |> render_click()
    view |> element("#confirm-cancel-mapping-grab-#{held.id} button", "Discard") |> render_click()

    refute has_element?(view, "#grab-#{held.id}")
    refute Repo.get(Grab, held.id)
    assert Repo.get!(Episode, episode.id).grab_id == nil
  end

  test "verification holds show retry and cancel without exposing mapping actions", %{
    conn: conn
  } do
    held = verification_grab!()

    {:ok, view, _html} = live(conn, ~p"/activity")

    # Goes through the shared badge_spec (kind: :grab, status: :verification_blocked), not a
    # hand-rolled span — same warning treatment as a movie held mid-verification.
    assert has_element?(view, "#grab-#{held.id} span.badge-warning", "Needs verification")
    assert has_element?(view, "#retry-verification-grab-#{held.id}", "Retry verification")
    assert has_element?(view, "#cancel-verification-grab-#{held.id}", "Cancel download")

    refute has_element?(view, "#grab-#{held.id}", "Retry import")
    refute has_element?(view, "#grab-#{held.id}", "Discard")
    refute has_element?(view, "#grab-#{held.id} input")
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

  test "a stale held confirmation cannot discard a grab a concurrent Retry already released", %{
    conn: conn
  } do
    grab = grab!() |> Repo.preload(:episodes)
    [episode] = grab.episodes

    held =
      grab
      |> Ecto.Changeset.change(%{
        mapping_snapshot: %{"version" => 2, "reserved_episode_ids" => [episode.id]},
        mapping_status: :needs_mapping,
        mapping_issue: %{"version" => 1, "reason" => "unresolved_file"}
      })
      |> Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/activity")
    view |> element("#ask-cancel-mapping-grab-#{held.id}") |> render_click()
    assert has_element?(view, "#confirm-cancel-mapping-grab-#{held.id}")

    # A concurrent Retry (e.g. from another admin tab) resolves the grab before this confirm
    # completes — the guarded discard must not undo it.
    assert {:ok, retried} = Catalog.retry_grab_mapping(held)

    render_click(view, "confirm_cancel_mapping", %{"id" => to_string(held.id)})

    assert Repo.get!(Cinder.Catalog.Grab, held.id).id == retried.id
    assert Repo.get!(Cinder.Catalog.Grab, held.id).mapping_status == :resolved
    assert Repo.get!(Cinder.Catalog.Episode, episode.id).grab_id == held.id
  end

  test "titles held on unsatisfiable Anime preferences surface with a reason and clear live", %{
    conn: conn
  } do
    series = series_fixture(%{title: "Re:Zero", year: 2016, media_profile: :anime})
    {:ok, series} = Catalog.set_anime_hold(series, :original_language_required)

    movie = movie_fixture(%{title: "Your Name", status: :searching, media_profile: :anime})
    {:ok, movie} = Catalog.set_anime_hold(movie, :original_language_required)

    {:ok, lv, html} = live(conn, ~p"/activity")

    # Held series get their own section (no movie row or grab exists to badge).
    assert html =~ "Held series"
    assert has_element?(lv, "#held-series-#{series.id} span.badge-warning", "Needs preferences")
    assert has_element?(lv, "#held-series-#{series.id}-reason", "original language")

    # A held movie reads "Needs preferences" in the pipeline (not a spinning "Searching").
    assert has_element?(lv, "#movie-#{movie.id} span.badge-warning", "Needs preferences")
    assert has_element?(lv, "#movie-#{movie.id}-hold-reason", "original language")

    # The sweep clearing the hold (preferences became satisfiable) updates the page live.
    {:ok, _} = Catalog.set_anime_hold(series, nil)
    {:ok, _} = Catalog.set_anime_hold(movie, nil)

    refute has_element?(lv, "#held-series-#{series.id}")
    refute has_element?(lv, "#movie-#{movie.id}-hold-reason")
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
