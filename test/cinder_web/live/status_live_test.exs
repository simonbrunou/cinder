defmodule CinderWeb.StatusLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Cinder.Catalog

  test "renders movies with status badges and live-updates on transition", %{conn: conn} do
    {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 9100, title: "Dune", year: 2021})

    {:ok, lv, html} = live(conn, ~p"/status")
    assert html =~ "Dune"
    assert html =~ "badge-neutral"

    {:ok, _} = Catalog.transition(movie, %{status: :downloading})
    assert render(lv) =~ "badge-primary"
  end

  test "prepends a movie whose first transition arrives after mount", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/status")

    {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 9101, title: "Arrival"})
    {:ok, _} = Catalog.transition(movie, %{status: :searching})

    html = render(lv)
    assert html =~ "Arrival"
    assert html =~ "badge-info"
  end
end
