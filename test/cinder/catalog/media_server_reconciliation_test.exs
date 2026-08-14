defmodule Cinder.Catalog.MediaServerReconciliationTest do
  use Cinder.DataCase, async: false

  import Cinder.CatalogFixtures

  alias Cinder.Catalog

  test "sets and clears exact movie matches, broadcasting each changed row once" do
    movie = movie_fixture(%{tmdb_id: 27_205})
    Catalog.subscribe()

    assert {:ok, [updated]} =
             Catalog.reconcile_media_server_items(:movies, [
               %{tmdb_id: 27_205, id: "plex:machine:42"},
               %{tmdb_id: 999, id: "plex:machine:99"}
             ])

    assert updated.media_server_item_id == "plex:machine:42"
    assert_receive {:movie_updated, %{id: id, media_server_item_id: "plex:machine:42"}}
    assert id == movie.id
    refute_receive {:movie_updated, _}

    assert {:ok, []} =
             Catalog.reconcile_media_server_items(:movies, [
               %{tmdb_id: 27_205, id: "plex:machine:42"}
             ])

    refute_receive {:movie_updated, _}

    assert {:ok, [%{media_server_item_id: nil}]} =
             Catalog.reconcile_media_server_items(:movies, [])

    assert_receive {:movie_updated, %{id: ^id, media_server_item_id: nil}}
  end

  test "series reconciliation writes through its dedicated changeset and broadcasts after update" do
    series = series_fixture(%{tmdb_id: 1399})
    Catalog.subscribe_series()

    assert {:ok, [updated]} =
             Catalog.reconcile_media_server_items(:tv, [
               %{tmdb_id: 1399, id: "jellyfin:series-1"}
             ])

    assert updated.media_server_item_id == "jellyfin:series-1"
    assert_receive {:series_updated, id}
    assert id == series.id
    assert Catalog.get_series_by_tmdb_id(1399).media_server_item_id == "jellyfin:series-1"
  end
end
