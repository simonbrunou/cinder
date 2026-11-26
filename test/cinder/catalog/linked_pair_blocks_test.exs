defmodule Cinder.Catalog.LinkedPairBlocksTest do
  @moduledoc """
  A scoped TV block also blocks its title under the linked indexer of the other source (#1673,
  #1622 point 3): Prowlarr indexer P pairs with the configured indexer the Prowlarr import linked
  to P, and that configured indexer pairs with P. Only content refusals cross.
  """
  use Cinder.DataCase, async: true

  import Cinder.CatalogFixtures

  alias Cinder.Catalog
  alias Cinder.Indexers

  @crossing [:add_rejected, :bad_torrent, :bad_download_file]

  setup do
    {:ok, native} =
      Indexers.create_imported(
        nil,
        %{name: "Linked", type: :newznab, base_url: "https://n.example", api_path: "/api"},
        %{},
        3
      )

    %{series: series_fixture(), native: native}
  end

  for reason <- @crossing do
    @reason reason

    test "a #{reason} block on Prowlarr 3 also blocks its title on the native indexer linked to 3",
         %{series: series, native: native} do
      :ok = Catalog.block_series_release(series.id, "T.S01E01", @reason, {"prowlarr", 3})

      assert Enum.sort(Catalog.blocked_release_titles_for_series(series.id)) ==
               Enum.sort([{"T.S01E01", {"prowlarr", 3}}, {"T.S01E01", {"native", native.id}}])
    end

    test "a #{reason} block on the native indexer linked to 3 also blocks its title on Prowlarr 3",
         %{series: series, native: native} do
      :ok = Catalog.block_series_release(series.id, "T.S01E01", @reason, {"native", native.id})

      assert Enum.sort(Catalog.blocked_release_titles_for_series(series.id)) ==
               Enum.sort([{"T.S01E01", {"native", native.id}}, {"T.S01E01", {"prowlarr", 3}}])
    end
  end

  test "an unsupported_download_url block stays in its own source, beside a bad_torrent that crosses",
       %{series: series, native: native} do
    :ok =
      Catalog.block_series_release(series.id, "T.S01E01", :unsupported_download_url, {
        "prowlarr",
        3
      })

    :ok = Catalog.block_series_release(series.id, "T.S01E02", :bad_torrent, {"prowlarr", 3})

    :ok =
      Catalog.block_series_release(series.id, "T.S01E03", :unsupported_download_url, {
        "native",
        native.id
      })

    assert Enum.sort(Catalog.blocked_release_titles_for_series(series.id)) ==
             Enum.sort([
               {"T.S01E01", {"prowlarr", 3}},
               {"T.S01E02", {"prowlarr", 3}},
               {"T.S01E02", {"native", native.id}},
               {"T.S01E03", {"native", native.id}}
             ])
  end

  test "a block on an indexer with no link gives only its own entry", %{series: series} do
    {:ok, unlinked} =
      Indexers.create(
        nil,
        %{name: "Unlinked", type: :newznab, base_url: "https://u.example", api_path: "/api"},
        %{}
      )

    :ok = Catalog.block_series_release(series.id, "T.S01E01", :bad_torrent, {"prowlarr", 9})

    :ok =
      Catalog.block_series_release(series.id, "T.S01E02", :bad_torrent, {"native", unlinked.id})

    assert Enum.sort(Catalog.blocked_release_titles_for_series(series.id)) ==
             Enum.sort([{"T.S01E01", {"prowlarr", 9}}, {"T.S01E02", {"native", unlinked.id}}])
  end

  test "a block with no indexer stays a bare title", %{series: series} do
    :ok = Catalog.block_series_release(series.id, "T.S01E01", :bad_torrent)

    assert Catalog.blocked_release_titles_for_series(series.id) == ["T.S01E01"]
  end

  test "a title blocked under both sides of the pair is listed once for each side",
       %{series: series, native: native} do
    :ok = Catalog.block_series_release(series.id, "T.S01E01", :bad_torrent, {"prowlarr", 3})

    :ok =
      Catalog.block_series_release(series.id, "T.S01E01", :add_rejected, {"native", native.id})

    assert Enum.sort(Catalog.blocked_release_titles_for_series(series.id)) ==
             Enum.sort([{"T.S01E01", {"prowlarr", 3}}, {"T.S01E01", {"native", native.id}}])
  end
end
