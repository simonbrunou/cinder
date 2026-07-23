defmodule CinderWeb.ActivityBeaconLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Cinder.Catalog

  # The beacon is rendered standalone (via root.html.heex in the real app); mount it in isolation.
  defp mount_beacon(conn), do: live_isolated(conn, CinderWeb.ActivityBeaconLive)

  test "counts an in-flight movie as active", %{conn: conn} do
    {:ok, _movie} = Catalog.add_movie(%{tmdb_id: 1, title: "Dune"})

    {:ok, _view, html} = mount_beacon(conn)

    assert html =~ "1 active"
  end

  test "hides the pill when nothing is in flight", %{conn: conn} do
    {:ok, _view, html} = mount_beacon(conn)

    refute html =~ "active"
    refute html =~ "need attention"
  end

  test "toasts and drops the active count when a movie goes available", %{conn: conn} do
    {:ok, movie} = Catalog.add_movie(%{tmdb_id: 2, title: "Arrival"})

    {:ok, view, _html} = mount_beacon(conn)
    assert render(view) =~ "1 active"

    Catalog.broadcast({:movie_updated, %{movie | status: :available}})

    html = render(view)
    assert html =~ "is now available"
    refute html =~ "1 active"
  end

  test "toasts and counts attention when a movie parks", %{conn: conn} do
    {:ok, movie} = Catalog.add_movie(%{tmdb_id: 3, title: "Solaris"})

    {:ok, view, _html} = mount_beacon(conn)

    Catalog.broadcast({:movie_updated, %{movie | status: :no_match}})

    html = render(view)
    assert html =~ "needs attention"
    assert html =~ "1 need attention"
  end

  test "does not re-toast on a repeat broadcast of the same status", %{conn: conn} do
    {:ok, movie} = Catalog.add_movie(%{tmdb_id: 4, title: "Contact"})
    {:ok, view, _html} = mount_beacon(conn)

    available = %{movie | status: :available}
    Catalog.broadcast({:movie_updated, available})
    assert render(view) =~ "is now available"

    # A metadata re-broadcast on an already-available movie must not spawn a second toast.
    Catalog.broadcast({:movie_updated, available})
    html = render(view)
    assert length(String.split(html, "is now available")) == 2
  end

  test "FR session: the available toast uses the localized title", %{conn: conn} do
    {:ok, movie} =
      Catalog.add_movie(%{
        tmdb_id: 5,
        title: "Arrival",
        localizations: %{"fr" => %{"title" => "Premier Contact"}}
      })

    {:ok, view, _html} =
      live_isolated(conn, CinderWeb.ActivityBeaconLive, session: %{"locale" => "fr"})

    Catalog.broadcast({:movie_updated, %{movie | status: :available}})

    html = render(view)
    assert html =~ "Premier Contact"
    refute html =~ "Arrival"
  end
end
