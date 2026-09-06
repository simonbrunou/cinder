defmodule CinderWeb.MyRequestsLiveTest do
  use CinderWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias Cinder.Books
  alias Cinder.Books.{BookGrab, Grabs}
  alias Cinder.Requests

  setup do
    stub(Cinder.Catalog.TMDBMock, :get_movie, fn _ -> {:error, :unavailable} end)
    stub(Cinder.Catalog.TMDBMock, :get_series, fn _ -> {:error, :unavailable} end)
    :ok
  end

  test "shows the current user's requests with status, not other users'", %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()
    other = Cinder.AccountsFixtures.user_fixture()

    {:ok, _} =
      Requests.create_request(user, %{
        target_type: "movie",
        target_id: 1,
        title: "Mine",
        year: 2001,
        poster_path: "/a.jpg"
      })

    {:ok, _} =
      Requests.create_request(other, %{
        target_type: "movie",
        target_id: 2,
        title: "Theirs",
        year: 2002,
        poster_path: "/b.jpg"
      })

    conn = log_in_user(conn, user)
    {:ok, lv, _html} = live(conn, ~p"/my-requests")

    assert has_element?(lv, "#my-requests", "Mine")
    refute has_element?(lv, "#my-requests", "Theirs")
    assert render(lv) =~ "Pending"
  end

  test "renders request and matching movie download progress", %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()
    tmdb_id = System.unique_integer([:positive])

    {:ok, _} =
      Requests.create_request(user, %{
        target_type: "movie",
        target_id: tmdb_id,
        title: "Progress",
        year: 2001
      })

    {:ok, movie} = Cinder.Catalog.add_movie(%{tmdb_id: tmdb_id, title: "Progress", year: 2001})
    {:ok, movie} = Cinder.Catalog.transition(movie, %{status: :downloading})

    {:ok, _} =
      Cinder.Catalog.update_movie_download_metrics(movie, %{
        download_progress: 0.42,
        download_speed: 1_500_000,
        download_eta: 90
      })

    conn = log_in_user(conn, user)
    {:ok, lv, _html} = live(conn, ~p"/my-requests")

    assert render(lv) =~ "Pending"
    assert render(lv) =~ "42%"
  end

  test "a season request shows the show title and season number", %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()

    {:ok, _} =
      Requests.create_request(user, %{
        target_type: "season",
        target_id: 1399,
        season_number: 3,
        title: "GoT",
        year: 2011
      })

    conn = log_in_user(conn, user)
    {:ok, _lv, html} = live(conn, ~p"/my-requests")
    assert html =~ "GoT"
    assert html =~ "Season 3"
  end

  test "season request row does not show movie pipeline badge even when a movie shares the same tmdb_id",
       %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()

    # season request with target_id 777
    {:ok, _} =
      Requests.create_request(user, %{
        target_type: "season",
        target_id: 777,
        season_number: 2,
        title: "Collision Show",
        year: 2020
      })

    # movie whose tmdb_id numerically matches the series tmdb_id
    {:ok, movie} =
      Cinder.Catalog.add_movie(%{
        tmdb_id: 777,
        title: "Collision Movie",
        year: 2019,
        poster_path: "/col.jpg"
      })

    {:ok, _} = Cinder.Catalog.transition(movie, %{status: :downloading})

    conn = log_in_user(conn, user)
    {:ok, _lv, html} = live(conn, ~p"/my-requests")

    # season row renders correctly
    assert html =~ "Collision Show"
    assert html =~ "Season 2"
    assert html =~ "Pending"

    # movie pipeline badge must NOT appear on the season row
    refute html =~ "Downloading"
  end

  test "live-updates when the user's request is approved", %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()
    admin = Cinder.AccountsFixtures.admin_fixture()

    {:ok, req} =
      Requests.create_request(user, %{
        target_type: "movie",
        target_id: 3,
        title: "Live",
        year: 2003,
        poster_path: "/c.jpg"
      })

    conn = log_in_user(conn, user)
    {:ok, lv, _html} = live(conn, ~p"/my-requests")

    stub(Cinder.Catalog.TMDBMock, :get_movie, fn id ->
      {:ok,
       %{
         tmdb_id: id,
         imdb_id: nil,
         title: "Live",
         year: 2003,
         poster_path: "/c.jpg",
         original_language: "en"
       }}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_movie_alternative_titles, fn _ -> {:ok, []} end)

    {:ok, _} = Requests.approve_request(req, admin, :standard)
    assert render(lv) =~ "Approved"
  end

  test "survives a {:movie_deleted, id} broadcast (reloads, no crash)", %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()
    conn = log_in_user(conn, user)
    {:ok, movie} = Cinder.Catalog.add_movie(%{tmdb_id: 9600, title: "Vanish"})

    {:ok, lv, _html} = live(conn, ~p"/my-requests")
    Cinder.Catalog.broadcast_movie_deleted(movie.id)
    # still alive after reload
    assert render(lv)
  end

  test "shows a plain-English hint for a parked movie", %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()
    tmdb_id = System.unique_integer([:positive])

    {:ok, _} =
      Requests.create_request(user, %{
        target_type: "movie",
        target_id: tmdb_id,
        title: "Solaris",
        year: 1972
      })

    {:ok, movie} = Cinder.Catalog.add_movie(%{tmdb_id: tmdb_id, title: "Solaris", year: 1972})
    {:ok, _movie} = Cinder.Catalog.transition(movie, %{status: :no_match})

    conn = log_in_user(conn, user)
    {:ok, _lv, html} = live(conn, ~p"/my-requests")

    assert html =~ "No release matched"
  end

  test "a requester can cancel their own pending request", %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()

    {:ok, req} =
      Requests.create_request(user, %{target_type: "movie", target_id: 42, title: "Cancel me"})

    conn = log_in_user(conn, user)
    {:ok, lv, _html} = live(conn, ~p"/my-requests")

    lv |> element("#cancel-request-#{req.id}") |> render_click()
    lv |> element("#confirm-cancel-request-#{req.id} button", "Cancel request") |> render_click()

    refute has_element?(lv, "#request-#{req.id}")
    assert Cinder.Repo.get(Cinder.Requests.Request, req.id) == nil
  end

  test "a denied request offers Request again, which re-submits through the gate", %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()
    admin = Cinder.AccountsFixtures.admin_fixture()

    {:ok, req} =
      Requests.create_request(user, %{target_type: "movie", target_id: 77, title: "Try again"})

    {:ok, _} = Requests.deny_request(req, admin, "not now")

    conn = log_in_user(conn, user)
    {:ok, lv, _html} = live(conn, ~p"/my-requests")

    assert has_element?(lv, "#request-again-#{req.id}")

    lv |> element("#request-again-#{req.id}") |> render_click()
    render_async(lv)

    # The denied row stays (its partial index slot is free), and a fresh pending request for the
    # same target now exists — the quota + approval gate ran, not a status flip.
    requests = Requests.list_for_user(user)
    assert Enum.any?(requests, &(&1.status == :pending and &1.target_id == 77))
    assert Enum.any?(requests, &(&1.id == req.id and &1.status == :denied))
  end

  describe "a book row is not a movie row" do
    setup do
      id = Integer.to_string(System.unique_integer([:positive]))

      {:ok, work} =
        Cinder.Books.upsert_work(%{
          title: "Denied Book #{id}",
          identifier: %{provider: "openlibrary", kind: "work", foreign_id: id}
        })

      %{work: work}
    end

    test "Request again on a denied book request carries its media kind", %{
      conn: conn,
      work: work
    } do
      user = Cinder.AccountsFixtures.user_fixture()
      admin = Cinder.AccountsFixtures.admin_fixture()

      {:ok, req} =
        Requests.create_request(user, %{
          target_type: "book",
          target_id: work.id,
          media_kind: :ebook
        })

      {:ok, _} = Requests.deny_request(req, admin, "not now")

      conn = log_in_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/my-requests")

      lv |> element("#request-again-#{req.id}") |> render_click()
      render_async(lv)

      assert Enum.any?(
               Requests.list_for_user(user),
               &(&1.status == :pending and &1.target_id == work.id and &1.media_kind == :ebook)
             )
    end

    test "an available movie sharing the work's id does not make the book row available", %{
      conn: conn,
      work: work
    } do
      user = Cinder.AccountsFixtures.user_fixture()

      # `movies_by_tmdb` is keyed by TMDB id; a book's target_id is a local book_works.id, so the
      # two id spaces can collide.
      Cinder.Repo.insert!(%Cinder.Catalog.Movie{
        tmdb_id: work.id,
        title: "Colliding Movie",
        status: :available,
        media_server_item_id: "collision"
      })

      {:ok, _} =
        Requests.create_request(user, %{
          target_type: "book",
          target_id: work.id,
          media_kind: :ebook
        })

      conn = log_in_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/my-requests")

      assert has_element?(lv, "#my-requests", "Denied Book")

      # Availability gates "Report an issue", and Cinder.Issues has no book snapshot, so the
      # button would raise on click.
      req = hd(Requests.list_for_user(user))
      refute has_element?(lv, "#report-issue-#{req.id}")
    end
  end

  describe "book target availability and holds (#494)" do
    setup do
      id = Integer.to_string(System.unique_integer([:positive]))

      {:ok, work} =
        Cinder.Books.upsert_work(%{
          title: "Tracked Book #{id}",
          identifier: %{provider: "openlibrary", kind: "work", foreign_id: id}
        })

      {:ok, profile} =
        Cinder.Catalog.create_profile(%{name: "Ebooks #{id}", kind: :ebook, handling: :standard})

      %{work: work, profile: profile}
    end

    defp approve_book(user, admin, work, media_kind, profile) do
      {:ok, request} =
        Requests.create_request(user, %{
          target_type: "book",
          target_id: work.id,
          media_kind: media_kind
        })

      {:ok, approved} = Requests.approve_request(request, admin, profile)
      {approved, hd(Books.list_targets(work))}
    end

    test "an approved eBook shows Available once its target is available", %{
      conn: conn,
      work: work,
      profile: profile
    } do
      user = Cinder.AccountsFixtures.user_fixture()
      admin = Cinder.AccountsFixtures.admin_fixture()

      {request, target} = approve_book(user, admin, work, :ebook, profile)

      {:ok, _file} =
        Books.Files.record_import(target, %{path: "/lib/book.epub", size: 1, format: :epub})

      conn = log_in_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/my-requests")

      html = lv |> element("#request-#{request.id}") |> render()
      assert html =~ "Available"
      refute html =~ "Approved"
    end

    test "an approved audiobook shows Needs attention once its target is held", %{
      conn: conn,
      work: work
    } do
      user = Cinder.AccountsFixtures.user_fixture()
      admin = Cinder.AccountsFixtures.admin_fixture()

      {:ok, audiobook_profile} =
        Cinder.Catalog.create_profile(%{
          name: "Audiobooks #{work.id}",
          kind: :audiobook,
          handling: :standard
        })

      {request, target} = approve_book(user, admin, work, :audiobook, audiobook_profile)
      {:ok, _held} = Books.hold_target(target, :test_reason)

      conn = log_in_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/my-requests")

      html = lv |> element("#request-#{request.id}") |> render()
      assert html =~ "Needs attention"
    end

    test "a book target broadcast updates the row live, without remount", %{
      conn: conn,
      work: work,
      profile: profile
    } do
      user = Cinder.AccountsFixtures.user_fixture()
      admin = Cinder.AccountsFixtures.admin_fixture()

      {request, target} = approve_book(user, admin, work, :ebook, profile)

      conn = log_in_user(conn, user)
      {:ok, lv, html} = live(conn, ~p"/my-requests")
      assert html =~ "Approved"

      {:ok, _file} =
        Books.Files.record_import(target, %{path: "/lib/book.epub", size: 1, format: :epub})

      render(lv)
      row_html = lv |> element("#request-#{request.id}") |> render()
      assert row_html =~ "Available"
      refute row_html =~ "Approved"
    end

    # PR #557 follow-up: a household is single-shared, so a SECOND requester's approval can
    # drive the SAME target the first requester's OWN request was denied against all the way to
    # :available. The first requester's row must keep reading Denied (it still renders its own
    # denial reason and Request again) — not silently start reading Available because someone
    # else's request happened to land on the shared target, which would erase the record that
    # THIS request was refused. (The shared, current-state book_badge_state/2 that Discover and
    # the book detail page use makes the opposite call on purpose — see its own moduledoc.)
    test "a denied row stays Denied even after a different requester's approval makes the shared target available",
         %{conn: conn, work: work, profile: profile} do
      denied_user = Cinder.AccountsFixtures.user_fixture()
      approved_user = Cinder.AccountsFixtures.user_fixture()
      admin = Cinder.AccountsFixtures.admin_fixture()

      {:ok, denied_request} =
        Requests.create_request(denied_user, %{
          target_type: "book",
          target_id: work.id,
          media_kind: :ebook
        })

      {:ok, denied_request} = Requests.deny_request(denied_request, admin, "not now")

      {approved_request, target} = approve_book(approved_user, admin, work, :ebook, profile)
      assert approved_request.target_id == denied_request.target_id

      {:ok, _file} =
        Books.Files.record_import(target, %{path: "/lib/shared.epub", size: 1, format: :epub})

      conn = log_in_user(conn, denied_user)
      {:ok, lv, _html} = live(conn, ~p"/my-requests")

      row_html = lv |> element("#request-#{denied_request.id}") |> render()
      assert row_html =~ "Denied"
      refute row_html =~ "Available"
    end

    # PR #557 review finding: Books.Grabs.track/2 broadcasts {:book_grab_updated, grab} on this
    # same topic on every transfer-metrics tick (normally every five seconds while a book
    # download is active), but this page renders no book-grab metrics. Before the fix the
    # catch-all handle_info/2 re-ran load/1 on every one of those ticks, hitting the DB with a
    # full reload (movies, series, requests, issues, settings, book target states) it could
    # never show anything for.
    test "a book-grab progress broadcast does not trigger a reload", %{
      conn: conn,
      work: work,
      profile: profile
    } do
      user = Cinder.AccountsFixtures.user_fixture()
      admin = Cinder.AccountsFixtures.admin_fixture()

      {_request, target} = approve_book(user, admin, work, :ebook, profile)

      grab =
        %BookGrab{}
        |> BookGrab.changeset(%{
          book_target_id: target.id,
          download_id: "grab-progress-#{target.id}",
          download_protocol: :torrent
        })
        |> Cinder.Repo.insert!()

      conn = log_in_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/my-requests")

      {_result, events} =
        Cinder.TelemetryHelpers.capture([:cinder, :repo, :query], fn ->
          {:ok, _updated} = Grabs.track(grab, %{download_progress: 42})
          render(lv)
        end)

      refute Enum.any?(events, fn {_measurements, metadata} ->
               is_binary(metadata.query) and String.contains?(metadata.query, ~s(FROM "requests"))
             end)
    end

    test "an eBook target's status does not affect the same work's audiobook row", %{
      conn: conn,
      work: work,
      profile: profile
    } do
      user = Cinder.AccountsFixtures.user_fixture()
      admin = Cinder.AccountsFixtures.admin_fixture()

      {:ok, audiobook_profile} =
        Cinder.Catalog.create_profile(%{
          name: "Audiobooks collision #{work.id}",
          kind: :audiobook,
          handling: :standard
        })

      {ebook_request, ebook_target} = approve_book(user, admin, work, :ebook, profile)

      {audiobook_request, _audiobook_target} =
        approve_book(user, admin, work, :audiobook, audiobook_profile)

      {:ok, _file} =
        Books.Files.record_import(ebook_target, %{path: "/lib/book.epub", size: 1, format: :epub})

      conn = log_in_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/my-requests")

      ebook_html = lv |> element("#request-#{ebook_request.id}") |> render()
      audiobook_html = lv |> element("#request-#{audiobook_request.id}") |> render()

      assert ebook_html =~ "Available"
      assert audiobook_html =~ "Approved"
      refute audiobook_html =~ "Available"
    end

    test "an available movie sharing the work's id as target_id does not affect the book row's badge",
         %{conn: conn, work: work, profile: profile} do
      user = Cinder.AccountsFixtures.user_fixture()
      admin = Cinder.AccountsFixtures.admin_fixture()

      Cinder.Repo.insert!(%Cinder.Catalog.Movie{
        tmdb_id: work.id,
        title: "Colliding Movie",
        status: :available,
        media_server_item_id: "collision-badge"
      })

      {request, _target} = approve_book(user, admin, work, :ebook, profile)

      conn = log_in_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/my-requests")

      html = lv |> element("#request-#{request.id}") |> render()
      assert html =~ "Approved"
      refute html =~ "Available"
    end
  end

  test "a pending request offers no Request again action", %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()

    {:ok, req} =
      Requests.create_request(user, %{target_type: "movie", target_id: 88, title: "Pending"})

    conn = log_in_user(conn, user)
    {:ok, lv, _html} = live(conn, ~p"/my-requests")

    refute has_element?(lv, "#request-again-#{req.id}")
  end

  test "every request row shows a relative requested-time line", %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()

    {:ok, _} =
      Requests.create_request(user, %{target_type: "movie", target_id: 55, title: "Freshly"})

    conn = log_in_user(conn, user)
    {:ok, _lv, html} = live(conn, ~p"/my-requests")

    # Just created, so the coarse bucket reads "just now".
    assert html =~ "Requested just now"
  end

  describe "season pipeline progress" do
    test "shows episode progress and a downloading badge while a season is still filling",
         %{conn: conn} do
      user = Cinder.AccountsFixtures.user_fixture()

      series = Cinder.CatalogFixtures.series_fixture(%{title: "Prog Show"})
      season = Cinder.CatalogFixtures.season_fixture(series, %{season_number: 2})

      Cinder.CatalogFixtures.episode_fixture(season, %{
        episode_number: 1,
        file_path: "/lib/Prog Show/Season 02/s02e01.mkv"
      })

      downloading = Cinder.CatalogFixtures.episode_fixture(season, %{episode_number: 2})
      Cinder.CatalogFixtures.episode_fixture(season, %{episode_number: 3})

      # An active grab on episode 2 → the season reads as downloading.
      {:ok, _grab} = Cinder.Catalog.create_grab("season-dl", :torrent, [downloading.id])

      {:ok, req} =
        Requests.create_request(user, %{
          target_type: "season",
          target_id: series.tmdb_id,
          season_number: 2,
          title: "Prog Show",
          year: 2008
        })

      conn = log_in_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/my-requests")

      assert has_element?(
               lv,
               "#request-#{req.id}-season-progress",
               "1 of 3 episodes available"
             )

      assert has_element?(lv, "#request-#{req.id} .badge", "Downloading")
    end

    test "no progress line for a season with no episodes yet (still pending approval)",
         %{conn: conn} do
      user = Cinder.AccountsFixtures.user_fixture()

      {:ok, req} =
        Requests.create_request(user, %{
          target_type: "season",
          target_id: 4242,
          season_number: 1,
          title: "Not Yet",
          year: 2024
        })

      conn = log_in_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/my-requests")

      refute has_element?(lv, "#request-#{req.id}-season-progress")
    end
  end

  describe "Open in media server on an available row" do
    test "an available movie row links to the media server", %{conn: conn} do
      put_media_server_web_url("https://plex.example.com")
      user = Cinder.AccountsFixtures.user_fixture()
      tmdb_id = System.unique_integer([:positive])

      {:ok, _} =
        Requests.create_request(user, %{
          target_type: "movie",
          target_id: tmdb_id,
          title: "Watchable",
          year: 2020
        })

      {:ok, movie} = Cinder.Catalog.add_movie(%{tmdb_id: tmdb_id, title: "Watchable", year: 2020})
      {:ok, _} = Cinder.Catalog.transition(movie, %{status: :available})

      conn = log_in_user(conn, user)
      {:ok, lv, html} = live(conn, ~p"/my-requests")

      assert has_element?(lv, ~s(a[href="https://plex.example.com"]), "Open in Plex")
      assert html =~ "opens in a new tab"
      assert html =~ ~s(rel="noopener")
    end

    test "an available movie row uses its reconciled title deep link", %{conn: conn} do
      put_media_server_web_url("https://plex.example.com")
      user = Cinder.AccountsFixtures.user_fixture()
      tmdb_id = System.unique_integer([:positive])

      {:ok, _} =
        Requests.create_request(user, %{
          target_type: "movie",
          target_id: tmdb_id,
          title: "Deep linked"
        })

      {:ok, movie} = Cinder.Catalog.add_movie(%{tmdb_id: tmdb_id, title: "Deep linked"})
      {:ok, _} = Cinder.Catalog.transition(movie, %{status: :available})

      assert {:ok, [_]} =
               Cinder.Catalog.reconcile_media_server_items(:movies, [
                 %{tmdb_id: tmdb_id, id: "plex:machine-1:77"}
               ])

      conn = log_in_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/my-requests")

      assert has_element?(
               lv,
               ~s(a[href="https://plex.example.com/web/index.html#!/server/machine-1/details?key=%2Flibrary%2Fmetadata%2F77"]),
               "Open in Plex"
             )
    end

    test "reloads its media-server link after a settings broadcast", %{conn: conn} do
      put_media_server_web_url("https://plex.example.com")
      user = Cinder.AccountsFixtures.user_fixture()
      tmdb_id = System.unique_integer([:positive])

      {:ok, _} =
        Requests.create_request(user, %{
          target_type: "movie",
          target_id: tmdb_id,
          title: "Switched server"
        })

      {:ok, movie} = Cinder.Catalog.add_movie(%{tmdb_id: tmdb_id, title: "Switched server"})
      {:ok, _} = Cinder.Catalog.transition(movie, %{status: :available})

      conn = log_in_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/my-requests")
      assert has_element?(lv, ~s(a[href="https://plex.example.com"]), "Open in Plex")

      jellyfin = Cinder.Library.MediaServer.Jellyfin
      previous = Application.get_env(:cinder, jellyfin, [])
      on_exit(fn -> Application.put_env(:cinder, jellyfin, previous) end)

      Application.put_env(
        :cinder,
        jellyfin,
        Keyword.put(previous, :web_url, "https://jellyfin.example.com")
      )

      Cinder.Repo.get_by!(Cinder.Settings.Setting, key: "media_server_type")
      |> Ecto.Changeset.change(value: "jellyfin")
      |> Cinder.Repo.update!()

      Phoenix.PubSub.broadcast(Cinder.PubSub, "settings", :settings_updated)

      assert has_element?(lv, ~s(a[href="https://jellyfin.example.com"]), "Open in Jellyfin")
      refute has_element?(lv, ~s(a[href="https://plex.example.com"]), "Open in Plex")
    end

    test "an available season row links to the media server", %{conn: conn} do
      put_media_server_web_url("https://plex.example.com")
      user = Cinder.AccountsFixtures.user_fixture()

      series = Cinder.CatalogFixtures.series_fixture(%{title: "Done Show"})
      season = Cinder.CatalogFixtures.season_fixture(series, %{season_number: 1})

      Cinder.CatalogFixtures.episode_fixture(season, %{
        episode_number: 1,
        file_path: "/lib/Done Show/Season 01/s01e01.mkv"
      })

      {:ok, _} =
        Requests.create_request(user, %{
          target_type: "season",
          target_id: series.tmdb_id,
          season_number: 1,
          title: "Done Show",
          year: 2008
        })

      conn = log_in_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/my-requests")

      assert has_element?(lv, ".badge", "Available")
      assert has_element?(lv, ~s(a[href="https://plex.example.com"]), "Open in Plex")
    end

    test "no media-server link when no web URL is configured", %{conn: conn} do
      user = Cinder.AccountsFixtures.user_fixture()
      tmdb_id = System.unique_integer([:positive])

      {:ok, _} =
        Requests.create_request(user, %{target_type: "movie", target_id: tmdb_id, title: "NoLink"})

      {:ok, movie} = Cinder.Catalog.add_movie(%{tmdb_id: tmdb_id, title: "NoLink"})
      {:ok, _} = Cinder.Catalog.transition(movie, %{status: :available})

      conn = log_in_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/my-requests")

      refute has_element?(lv, "a", "Open in")
    end
  end

  describe "report an issue" do
    setup %{conn: conn} do
      user = Cinder.AccountsFixtures.user_fixture()
      tmdb_id = System.unique_integer([:positive])

      {:ok, _} =
        Requests.create_request(user, %{target_type: "movie", target_id: tmdb_id, title: "Dune"})

      {:ok, movie} = Cinder.Catalog.add_movie(%{tmdb_id: tmdb_id, title: "Dune"})
      {:ok, _} = Cinder.Catalog.transition(movie, %{status: :available})

      %{conn: log_in_user(conn, user), tmdb_id: tmdb_id}
    end

    test "an available row offers the action and files a report", %{conn: conn, tmdb_id: tmdb_id} do
      {:ok, lv, _html} = live(conn, ~p"/my-requests")

      request_id = report_request_id(lv)
      assert has_element?(lv, "#report-issue-#{request_id}")

      lv |> element("#report-issue-#{request_id}") |> render_click()

      lv
      |> form("#report-form-#{request_id}", %{"category" => "subtitles", "detail" => "no subs"})
      |> render_submit()

      assert render(lv) =~ "Your report was sent"
      assert [report] = Cinder.Issues.list_open()
      assert report.target_id == tmdb_id
      assert report.category == :subtitles
      assert report.detail == "no subs"

      # Now that a report is open, the action is replaced by the "Reported" pill.
      refute has_element?(lv, "#report-issue-#{request_id}")
      assert render(lv) =~ "Reported"
    end
  end

  defp report_request_id(lv) do
    [_, id] = Regex.run(~r/report-issue-(\d+)/, render(lv))
    id
  end

  # Mirrors movie_discovery_live_test: writes the media_server_type row directly (Settings.put/2
  # would run load_into_env/0 and flip the global :media_server impl off the Mox mock for the
  # rest of the run). media_server_web_link/0 reads the row plus the impl's :web_url.
  defp put_media_server_web_url(url) do
    module = Cinder.Library.MediaServer.Plex
    previous = Application.get_env(:cinder, module, [])
    on_exit(fn -> Application.put_env(:cinder, module, previous) end)

    Cinder.Repo.insert!(%Cinder.Settings.Setting{
      key: "media_server_type",
      value: "plex",
      is_secret: false
    })

    Application.put_env(:cinder, module, Keyword.put(previous, :web_url, url))
  end
end
