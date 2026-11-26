defmodule Cinder.Download.LinkedPairBlockPollTest do
  @moduledoc """
  A TV poll after a Prowlarr import (#1673): the import links a configured indexer to the
  Prowlarr indexer it came from, and a series block that a content refusal left under one of the
  two skips its title from the other. A configured indexer the import did not link to that
  Prowlarr indexer is no pair, and its copy is grabbed.

  Each search result carries its own download link. The blocked title's copy is the
  higher-ranked one, and a lower-ranked 720p release with another title is the positive control:
  the poll that skips the blocked title grabs the control instead.
  """
  use Cinder.DataCase, async: false

  import Ecto.Query
  import Mox
  import Cinder.CatalogFixtures
  import Cinder.PollerHelpers, only: [stub_clean_content: 0]

  alias Cinder.Catalog
  alias Cinder.Catalog.Grab
  alias Cinder.Download.{Intent, TvPoller}
  alias Cinder.Indexers

  @moduletag :capture_log

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    on_exit(fn -> :persistent_term.erase({TvPoller, :last_run}) end)
    stub_clean_content()
  end

  @episode "Show.S01E01.1080p.WEB-DL-GRP"
  @control "Show.S01E01.720p.WEB-DL-CTRL"

  for {blocked_as, from} <- [{:prowlarr, :native}, {:native, :prowlarr}] do
    @blocked_as blocked_as
    @from from

    test "a title refused under the #{blocked_as} side of an import link is skipped from its #{from} side" do
      linked = imported_indexer!("Linked", 3)
      series = wanted_episode!()

      block_source =
        if @blocked_as == :prowlarr, do: {"prowlarr", 3}, else: {"native", linked.id}

      :ok = Catalog.block_series_release(series.id, @episode, :bad_torrent, block_source)

      linked_copy =
        if @from == :native,
          do: native_result(@episode, "linked", linked, 20),
          else: Map.put(result(@episode, "linked", 3, 20), :indexer_source, "prowlarr")

      stub_results([linked_copy, native_result(@control, "control", linked, 5)])
      stub_client()

      poll_once()

      assert added() == ["control"]
      assert grabbed() == ["hash-control"]
    end
  end

  test "a title refused under a Prowlarr indexer is grabbed from a configured indexer not linked to it" do
    _linked = imported_indexer!("Linked", 3)

    {:ok, other} =
      Indexers.create(
        nil,
        %{name: "Other", type: :newznab, base_url: "https://o.example", api_path: "/api"},
        %{"api_key" => "nzb-key-0123456789"}
      )

    series = wanted_episode!()
    :ok = Catalog.block_series_release(series.id, @episode, :bad_torrent, {"prowlarr", 3})

    stub_results([
      native_result(@episode, "other", other, 20),
      native_result(@control, "control", other, 5)
    ])

    stub_client()

    poll_once()

    assert added() == ["other"]
    assert grabbed() == ["hash-other"]
  end

  # The search keeps one copy of a link per indexer (architecture.md "TV search results are
  # deduped per link and indexer"), so the linked indexer's blocked copy leaves the other
  # indexer's copy of the same link a candidate, and the grab names that indexer.
  test "one link from the linked indexer and an unlinked one is grabbed from the unlinked one" do
    linked = imported_indexer!("Linked", 3)

    {:ok, other} =
      Indexers.create(
        nil,
        %{name: "Other", type: :newznab, base_url: "https://o.example", api_path: "/api"},
        %{"api_key" => "nzb-key-0123456789"}
      )

    series = wanted_episode!()
    :ok = Catalog.block_series_release(series.id, @episode, :bad_torrent, {"prowlarr", 3})

    stub_results([
      native_result(@episode, "shared", linked, 20),
      native_result(@episode, "shared", other, 10),
      native_result(@control, "control", linked, 5)
    ])

    stub_client()
    test_pid = self()

    stub(Cinder.Download.ClientMock, :find_by_operation_key, fn _key ->
      send(test_pid, {:intents, Repo.all(Intent)})
      :not_found
    end)

    poll_once()

    assert added() == ["shared"]
    assert grabbed() == ["hash-shared"]
    assert_received {:intents, [%Intent{release: stored}]}
    assert {stored["indexer_source"], stored["indexer_id"]} == {"native", other.id}
  end

  defp poll_once do
    start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})
    assert :ok = TvPoller.poll()
  end

  defp wanted_episode! do
    series = series_fixture(%{tvdb_id: 99, monitor_strategy: :all})
    episode_fixture(season_fixture(series), %{episode_number: 1})
    series
  end

  # A configured indexer that a Prowlarr import linked to Prowlarr indexer `prowlarr_id`.
  defp imported_indexer!(name, prowlarr_id) do
    {:ok, row} =
      Indexers.create_imported(
        nil,
        %{
          name: name,
          type: :newznab,
          base_url: "https://#{String.downcase(name)}.example",
          api_path: "/api"
        },
        %{"api_key" => "nzb-key-0123456789"},
        prowlarr_id
      )

    row
  end

  defp stub_results(results) do
    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 99, _title, 1 -> {:ok, results} end)
    stub(Cinder.Acquisition.IndexerMock, :search_tv_query, fn _query, _opts -> {:ok, results} end)
  end

  defp result(title, link, indexer_id, seeders) do
    %{
      title: title,
      size: 2_000_000_000,
      download_url: link,
      seeders: seeders,
      indexer_id: indexer_id
    }
  end

  # A search result from configured indexer `row` at its current credentials version.
  defp native_result(title, link, row, seeders) do
    title
    |> result(link, row.id, seeders)
    |> Map.merge(%{indexer_source: "native", credentials_version: row.credentials_version})
  end

  # The client adds every link, and each `add` reports its link to the test.
  defp stub_client do
    test_pid = self()
    stub(Cinder.Download.ClientMock, :find_by_operation_key, fn _key -> :not_found end)
    stub(Cinder.Download.ClientMock, :status, fn _id -> {:ok, %{state: :downloading}} end)

    stub(Cinder.Download.ClientMock, :add, fn release, _opts ->
      send(test_pid, {:add, release.download_url})
      {:ok, "hash-#{release.download_url}"}
    end)
  end

  defp added, do: collect_added([])

  defp collect_added(links) do
    receive do
      {:add, link} -> collect_added([link | links])
    after
      0 -> Enum.reverse(links)
    end
  end

  defp grabbed, do: Repo.all(from g in Grab, order_by: g.id, select: g.download_id)
end
