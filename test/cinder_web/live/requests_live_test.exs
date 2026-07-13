defmodule CinderWeb.RequestsLiveTest do
  use CinderWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mox
  import Cinder.AccountsFixtures

  setup :register_and_log_in_admin
  setup :set_mox_global

  setup do
    stub(Cinder.Catalog.TMDBMock, :get_movie, fn id ->
      {:ok,
       %{
         tmdb_id: id,
         imdb_id: nil,
         title: "Movie #{id}",
         year: nil,
         poster_path: nil,
         original_language: "en"
       }}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_movie_alternative_titles, fn _ -> {:ok, []} end)
    :ok
  end

  test "lists pending and approves", %{conn: conn} do
    user = user_fixture()

    {:ok, req} =
      Cinder.Requests.create_request(user, %{
        target_type: "movie",
        target_id: 603,
        title: "The Matrix"
      })

    {:ok, lv, html} = live(conn, ~p"/requests")
    assert html =~ "The Matrix"
    lv |> element("button", "Approve") |> render_click()
    render_async(lv)
    assert [%Cinder.Catalog.Movie{status: :requested}] = Cinder.Catalog.list_by_status(:requested)
    assert {:ok, %{status: :approved}} = {:ok, Cinder.Repo.reload(req)}
  end

  test "approval defaults to the proposal and requires an explicit Standard or Anime choice", %{
    conn: conn
  } do
    user = user_fixture()

    {:ok, req} =
      Cinder.Requests.create_request(user, %{
        target_type: "movie",
        target_id: 604,
        title: "Akira",
        proposed_media_profile: :anime
      })

    {:ok, lv, _html} = live(conn, ~p"/requests")
    selector = "#approval-profile-#{req.id}"
    assert has_element?(lv, "#{selector} option[value='anime'][selected]")

    lv
    |> form("#approval-profile-form-#{req.id}", %{
      "_id" => to_string(req.id),
      "profile" => "standard"
    })
    |> render_change()

    lv |> element("button[phx-click='approve'][phx-value-id='#{req.id}']") |> render_click()
    render_async(lv)

    assert Cinder.Catalog.get_movie_by_tmdb_id(604).media_profile == :standard
  end

  test "bulk approval uses each row's confirmed profile", %{conn: conn} do
    user = user_fixture()

    {:ok, standard} =
      Cinder.Requests.create_request(user, %{
        target_type: "movie",
        target_id: 605,
        title: "Standard"
      })

    {:ok, anime} =
      Cinder.Requests.create_request(user, %{
        target_type: "movie",
        target_id: 606,
        title: "Anime",
        proposed_media_profile: :anime
      })

    {:ok, lv, _html} = live(conn, ~p"/requests")
    render_hook(lv, "toggle_select", %{"id" => to_string(standard.id)})
    render_hook(lv, "toggle_select", %{"id" => to_string(anime.id)})
    render_hook(lv, "approve_selected", %{})
    render_async(lv)

    assert Cinder.Catalog.get_movie_by_tmdb_id(605).media_profile == :standard
    assert Cinder.Catalog.get_movie_by_tmdb_id(606).media_profile == :anime
  end

  test "reopen returns a denied request to pending", %{conn: conn} do
    user = user_fixture()
    admin = admin_fixture()

    {:ok, req} =
      Cinder.Requests.create_request(user, %{
        target_type: "movie",
        target_id: 603,
        title: "The Matrix"
      })

    {:ok, _} = Cinder.Requests.deny_request(req, admin, "later")

    {:ok, lv, _html} = live(conn, ~p"/requests")
    lv |> element("button", "Reopen") |> render_click()
    assert %{status: :pending} = Cinder.Repo.reload(req)
  end

  test "bulk approve approves every selected pending request", %{conn: conn} do
    user = user_fixture()

    {:ok, r1} =
      Cinder.Requests.create_request(user, %{
        target_type: "movie",
        target_id: 603,
        title: "The Matrix"
      })

    {:ok, r2} =
      Cinder.Requests.create_request(user, %{
        target_type: "movie",
        target_id: 27_205,
        title: "Inception"
      })

    {:ok, lv, _html} = live(conn, ~p"/requests")
    render_hook(lv, "toggle_select", %{"id" => to_string(r1.id)})
    render_hook(lv, "toggle_select", %{"id" => to_string(r2.id)})
    render_hook(lv, "approve_selected", %{})
    # Bulk approve now runs off the LiveView via start_async; wait for the task to settle.
    render_async(lv)

    assert %{status: :approved} = Cinder.Repo.reload(r1)
    assert %{status: :approved} = Cinder.Repo.reload(r2)
  end

  test "a non-admin cannot reach /requests", %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/requests")
  end

  # Robustness: malformed/forged events must not crash the LiveView.
  # These tests verify the fix for String.to_integer/1 raising on non-integer
  # client input, and missing catch-all handle_event/3.

  test "approve with non-integer id does not crash the LiveView", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/requests")
    render_hook(lv, "approve", %{"id" => "not-an-int"})
    # LiveView process must still be alive
    assert render(lv) =~ "Requests"
  end

  test "start_deny with non-integer id does not crash the LiveView", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/requests")
    render_hook(lv, "start_deny", %{"id" => "not-an-int"})
    assert render(lv) =~ "Requests"
  end

  test "deny with non-integer _id does not crash the LiveView", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/requests")
    render_hook(lv, "deny", %{"_id" => "not-an-int", "reason" => "bad input"})
    assert render(lv) =~ "Requests"
  end

  test "unknown event name does not crash the LiveView", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/requests")
    render_hook(lv, "bogus", %{})
    assert render(lv) =~ "Requests"
  end

  test "a pending season request appears in the queue with its season label", %{conn: conn} do
    user = user_fixture()

    {:ok, _} =
      Cinder.Requests.create_request(user, %{
        target_type: "season",
        target_id: 1399,
        season_number: 2,
        title: "Breaking Bad",
        year: 2008
      })

    {:ok, _lv, html} = live(conn, ~p"/requests")
    assert html =~ "Breaking Bad"
    assert html =~ "Season 2"
  end

  test "the pending queue shows the poster", %{conn: conn} do
    user = user_fixture()

    {:ok, _} =
      Cinder.Requests.create_request(user, %{
        target_type: "movie",
        target_id: 9,
        title: "P",
        year: 2009,
        poster_path: "/poster.jpg"
      })

    {:ok, _lv, html} = live(conn, ~p"/requests")
    assert html =~ "/poster.jpg"
  end

  test "approving a season request that fails TMDB lookup shows an error flash and leaves request pending",
       %{conn: conn} do
    user = user_fixture()

    {:ok, req} =
      Cinder.Requests.create_request(user, %{
        target_type: "season",
        target_id: 1399,
        season_number: 2,
        title: "Breaking Bad",
        year: 2008
      })

    # Stub TMDB to fail so find_or_create_series_at_requested → approve_request returns {:error, _}
    stub(Cinder.Catalog.TMDBMock, :get_series, fn _id ->
      {:error, {:tmdb_status, 503}}
    end)

    {:ok, lv, _html} = live(conn, ~p"/requests")
    lv |> element("button", "Approve") |> render_click()
    # The single approve runs via start_async (season approvals do blocking TMDB I/O).
    html = render_async(lv)

    assert html =~ "Couldn&#39;t approve"

    # Request must still be :pending — no state change
    reloaded = Cinder.Repo.reload(req)
    assert reloaded.status == :pending
  end

  test "lists requests of every status with a badge", %{conn: conn} do
    user = user_fixture()
    admin = admin_fixture()

    {:ok, _pending} =
      Cinder.Requests.create_request(user, %{target_type: "movie", target_id: 1, title: "Pend"})

    {:ok, to_deny} =
      Cinder.Requests.create_request(user, %{target_type: "movie", target_id: 2, title: "Den"})

    {:ok, _denied} = Cinder.Requests.deny_request(to_deny, admin, "no")

    {:ok, _lv, html} = live(conn, ~p"/requests")
    assert html =~ "Pend"
    assert html =~ "Den"
    # status badges render (status_badge prints the Title-cased label)
    assert html =~ "Pending"
    assert html =~ "Denied"
  end

  test "deleting a request shows the orphan/re-request warning then removes it", %{conn: conn} do
    user = user_fixture()

    {:ok, req} =
      Cinder.Requests.create_request(user, %{
        target_type: "movie",
        target_id: 3,
        title: "ToDelete"
      })

    {:ok, lv, _html} = live(conn, ~p"/requests")

    # open the confirm panel for this request
    confirm_html =
      lv
      |> element("button[phx-click='start_delete'][phx-value-id='#{req.id}']")
      |> render_click()

    assert confirm_html =~ "Deleting a request does not remove"
    assert confirm_html =~ "can be requested again"

    # confirm the delete
    deleted_html =
      lv |> element("button[phx-click='delete'][phx-value-id='#{req.id}']") |> render_click()

    assert deleted_html =~ "Request deleted."
    assert Cinder.Repo.get(Cinder.Requests.Request, req.id) == nil
    refute render(lv) =~ "ToDelete"
  end

  test "cancel_delete closes the confirm panel without deleting", %{conn: conn} do
    user = user_fixture()

    {:ok, req} =
      Cinder.Requests.create_request(user, %{target_type: "movie", target_id: 4, title: "Keep"})

    {:ok, lv, _html} = live(conn, ~p"/requests")
    lv |> element("button[phx-click='start_delete'][phx-value-id='#{req.id}']") |> render_click()
    lv |> element("button[phx-click='cancel_delete']") |> render_click()

    assert Cinder.Repo.get(Cinder.Requests.Request, req.id)
    assert render(lv) =~ "Keep"
  end

  test "delete with a forged non-integer id does not crash the LiveView", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/requests")
    render_hook(lv, "delete", %{"id" => "not-an-int"})
    assert render(lv) =~ "Requests"
  end

  test "delete with an unknown id does not crash the LiveView", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/requests")
    render_hook(lv, "delete", %{"id" => "999999"})
    assert render(lv) =~ "Requests"
  end
end
