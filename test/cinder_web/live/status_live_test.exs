defmodule CinderWeb.StatusLiveTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

  alias Cinder.Catalog

  # The health panel runs its checks in a start_async task (a separate process),
  # so the mocks must be global. Default every service healthy; tests that care
  # override specific services.
  setup :set_mox_global

  setup do
    stub(Cinder.Acquisition.IndexerMock, :health, fn -> :ok end)
    stub(Cinder.Download.ClientMock, :health, fn -> :ok end)
    stub(Cinder.Download.SabnzbdClientMock, :health, fn -> :ok end)
    stub(Cinder.Library.MediaServerMock, :health, fn -> :ok end)
    :ok
  end

  test "renders movies with status badges and live-updates on transition", %{conn: conn} do
    {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 9100, title: "Dune", year: 2021})

    {:ok, lv, html} = live(conn, ~p"/status")
    assert html =~ "Dune"
    assert html =~ "badge-neutral"

    {:ok, _} = Catalog.transition(movie, %{status: :downloading})
    assert render(lv) =~ "badge-primary"
  end

  test "a parked movie shows a Retry button that re-queues it to :requested", %{conn: conn} do
    {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 9200, title: "Tenet"})
    {:ok, _} = Catalog.transition(movie, %{status: :no_match})

    {:ok, lv, _html} = live(conn, ~p"/status")

    lv |> element("#movie-#{movie.id} button", "Retry") |> render_click()

    html = render(lv)
    assert html =~ "badge-neutral"
    assert Catalog.get_movie_by_id(movie.id).status == :requested
  end

  test "an in-flight movie shows no Retry button", %{conn: conn} do
    {:ok, movie} = Catalog.add_to_watchlist(%{tmdb_id: 9201, title: "Sicario"})
    {:ok, _} = Catalog.transition(movie, %{status: :downloading, download_id: "h"})

    {:ok, lv, _html} = live(conn, ~p"/status")

    refute has_element?(lv, "#movie-#{movie.id} button", "Retry")
  end

  test "renders a service-health panel with per-service badges", %{conn: conn} do
    stub(Cinder.Download.ClientMock, :health, fn -> {:error, :econnrefused} end)

    {:ok, lv, _html} = live(conn, ~p"/status")
    html = render_async(lv)

    assert html =~ "Service health"
    assert html =~ "Indexer (IndexerMock)"
    assert html =~ "Download (torrent"
    assert html =~ "badge-success"
    # the down torrent client
    assert html =~ "badge-error"
  end

  test "Recheck re-runs the health checks", %{conn: conn} do
    stub(Cinder.Acquisition.IndexerMock, :health, fn -> {:error, :down} end)

    {:ok, lv, _html} = live(conn, ~p"/status")
    assert render_async(lv) =~ "badge-error"

    # Indexer recovers; clicking Recheck should clear the error.
    stub(Cinder.Acquisition.IndexerMock, :health, fn -> :ok end)

    lv |> element("#recheck-health") |> render_click()
    refute render_async(lv) =~ "badge-error"
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
