defmodule CinderWeb.SeriesDiscoveryLiveTest do
  use CinderWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mox

  setup :set_mox_global

  setup do
    stub(Cinder.Catalog.TMDBMock, :get_series, fn 1399 ->
      {:ok,
       %{
         tmdb_id: 1399,
         tvdb_id: 1,
         title: "GoT",
         year: 2011,
         poster_path: nil,
         # Season 0 (Specials) + two real seasons — used by Bug B test
         seasons: [%{season_number: 0}, %{season_number: 1}, %{season_number: 2}]
       }}
    end)

    :ok
  end

  test "renders the page under the shared header", %{conn: conn} do
    conn = log_in_user(conn, Cinder.AccountsFixtures.user_fixture())
    {:ok, _lv, html} = live(conn, ~p"/series/tmdb/1399")
    assert html =~ "GoT"
    refute html =~ ~s(<h1 class="text-2xl font-semibold">)
  end

  test "lists seasons from TMDB with Request buttons for a not-yet-added show", %{conn: conn} do
    conn = log_in_user(conn, Cinder.AccountsFixtures.user_fixture())
    {:ok, lv, html} = live(conn, ~p"/series/tmdb/1399")
    assert html =~ "GoT"
    assert has_element?(lv, ~s(button[phx-value-season="1"]), "Request")
    assert has_element?(lv, ~s(button[phx-value-season="2"]), "Request")
  end

  # Bug B: season 0 (Specials) must not be rendered at all — the TV poller excludes it.
  test "season 0 (Specials) is not rendered", %{conn: conn} do
    conn = log_in_user(conn, Cinder.AccountsFixtures.user_fixture())
    {:ok, lv, _html} = live(conn, ~p"/series/tmdb/1399")
    refute has_element?(lv, ~s(button[phx-value-season="0"]))
    refute render(lv) =~ "Specials"
  end

  test "requesting a season creates a pending request and swaps the button for a badge", %{
    conn: conn
  } do
    user = Cinder.AccountsFixtures.user_fixture()
    conn = log_in_user(conn, user)
    {:ok, lv, _} = live(conn, ~p"/series/tmdb/1399")
    lv |> element(~s(button[phx-value-season="2"]), "Request") |> render_click()
    # The request runs via start_async (an admin/auto-approve one does seconds of TMDB I/O).
    html = render_async(lv)

    assert [%{target_type: "season", target_id: 1399, season_number: 2, status: :pending}] =
             Cinder.Requests.list_for_user(user)

    assert html =~ "Pending"
  end

  test "a denied season still shows a Request button so the user can re-request", %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()
    admin = Cinder.AccountsFixtures.admin_fixture()

    # Create a request and deny it to set up the denied state.
    attrs = %{
      target_type: "season",
      target_id: 1399,
      season_number: 1,
      title: "GoT",
      year: 2011,
      poster_path: nil
    }

    {:ok, request} = Cinder.Requests.create_request(user, attrs)
    {:ok, _} = Cinder.Requests.deny_request(request, admin, "Not available")

    conn = log_in_user(conn, user)
    {:ok, lv, _html} = live(conn, ~p"/series/tmdb/1399")

    # The denied badge is shown alongside the Request button (parity with DiscoverLive).
    assert has_element?(lv, ~s(.badge), "Denied")
    assert has_element?(lv, ~s(button[phx-value-season="1"]), "Request")

    # Clicking Request creates a fresh pending request (off-process via start_async).
    lv |> element(~s(button[phx-value-season="1"]), "Request") |> render_click()
    html = render_async(lv)

    requests = Cinder.Requests.list_for_user(user)

    assert Enum.any?(requests, &(&1.season_number == 1 and &1.status == :pending))

    # Bug A: the badge must now show "Pending" — not "Denied" — and the Request button
    # must be gone for season 1 (newest request wins over the older denied one).
    assert html =~ "Pending"
    refute has_element?(lv, ~s(button[phx-value-season="1"]), "Request")
  end

  # Bug C: a forged/absent season_number that is not in the show must be rejected.
  test "requesting a season not in the show is silently rejected", %{conn: conn} do
    user = Cinder.AccountsFixtures.user_fixture()
    conn = log_in_user(conn, user)
    {:ok, lv, _} = live(conn, ~p"/series/tmdb/1399")

    # Season 99 is not in the stub (only 0, 1, 2 are).
    render_click(lv, "request_season", %{"season" => "99"})

    assert Cinder.Requests.list_for_user(user) == []
  end
end
