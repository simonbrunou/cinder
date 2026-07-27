defmodule CinderWeb.IssuesLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Cinder.AccountsFixtures
  import Cinder.CatalogFixtures

  alias Cinder.Issues

  defp open_report(user, title) do
    movie = movie_fixture(%{status: :available, title: title})

    {:ok, report} =
      Issues.create_report(user, %{
        target_type: "movie",
        target_id: movie.tmdb_id,
        category: "audio",
        detail: "no sound in #{title}"
      })

    report
  end

  test "lists open reports with requester, title, category, and detail", %{conn: conn} do
    admin = admin_fixture()
    user = user_fixture()
    open_report(user, "Dune")

    {:ok, _lv, html} = conn |> log_in_user(admin) |> live(~p"/issues")

    assert html =~ "Dune"
    assert html =~ user.email
    assert html =~ "Audio problem"
    assert html =~ "no sound in Dune"
  end

  test "resolve closes the report and notifies the reporter", %{conn: conn} do
    admin = admin_fixture()
    user = user_fixture()
    report = open_report(user, "Dune")

    Cinder.TestNotifier.subscribe()
    {:ok, lv, _html} = conn |> log_in_user(admin) |> live(~p"/issues")

    lv |> element(~s(#issue-report-#{report.id} button), "Resolve") |> render_click()

    assert_receive {:notify, {:issue_resolved, resolved}}
    assert resolved.id == report.id
    refute has_element?(lv, "#issue-report-#{report.id}")
    assert render(lv) =~ "No open issues"
  end

  test "dismiss closes the report without a resolved notification", %{conn: conn} do
    admin = admin_fixture()
    user = user_fixture()
    report = open_report(user, "Dune")

    Cinder.TestNotifier.subscribe()
    {:ok, lv, _html} = conn |> log_in_user(admin) |> live(~p"/issues")

    lv |> element(~s(#issue-report-#{report.id} button), "Dismiss") |> render_click()

    assert_receive {:notify, {:issue_dismissed, _}}
    refute_receive {:notify, {:issue_resolved, _}}
    refute has_element?(lv, "#issue-report-#{report.id}")
  end

  test "a new report appears live via the issues topic", %{conn: conn} do
    admin = admin_fixture()
    user = user_fixture()

    {:ok, lv, _html} = conn |> log_in_user(admin) |> live(~p"/issues")
    assert render(lv) =~ "No open issues"

    open_report(user, "Arrival")

    assert render(lv) =~ "Arrival"
  end

  test "a non-admin cannot reach the issues queue", %{conn: conn} do
    user = user_fixture()
    assert {:error, {:redirect, _}} = conn |> log_in_user(user) |> live(~p"/issues")
  end
end
