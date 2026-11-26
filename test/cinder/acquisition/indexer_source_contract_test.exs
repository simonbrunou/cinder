defmodule Cinder.Acquisition.IndexerSourceContractTest do
  # The `Cinder.Acquisition.IndexerSource` contract, one loop over every source (#1624 point 2,
  # #1651): each of the eight search callbacks answers `{:ok, rows}`, `{:ok, rows, report}` or
  # `{:error, _}`, and every row carries a non-blank title, a download link, a protocol, its
  # indexer's id and name, and its query origins. Prowlarr runs behind its `Req.Test` stub, Native
  # behind a Mox mock of the per-type seam. Not async: Native's adapter map is global.
  #
  # Listed exceptions, each asserted exactly below:
  # - Prowlarr answers `{:ok, []}` when every indexer it asks is down: its API returns `[]`.
  # - Prowlarr tags no query origin on `search/1`, `search_movie_query/2` and `search_tv_query/2`,
  #   and `search_tv/3` merges both origins onto a link both of its queries return. Callers read a
  #   missing origin as untagged (`Cinder.Acquisition.title_guard/2`), so this PR leaves them.
  use Cinder.DataCase, async: false

  import Mox

  alias Cinder.Acquisition.IndexerAdapterMock
  alias Cinder.Acquisition.IndexerSource.{Native, Prowlarr, Report}
  alias Cinder.ConfigCase
  alias Cinder.Indexers

  setup :verify_on_exit!

  @callbacks [
    {:search, ["tt0000001"], :id_scoped},
    {:search_movie_query, ["Title", []], :free_text},
    {:search_tv_query, ["Show", []], :free_text},
    {:search_tv, [81_189, "Show", 1], :id_scoped},
    {:search_ebook, ["Author", "Title", []], :id_scoped},
    {:search_ebook_query, ["Title", []], :free_text},
    {:search_audiobook, ["Author", "Title", []], :id_scoped},
    {:search_audiobook_query, ["Title", []], :free_text}
  ]

  # The query origins Prowlarr tags, per callback: nil for none.
  @prowlarr_origins %{
    search: nil,
    search_movie_query: nil,
    search_tv_query: nil,
    search_tv: [[:id_scoped], [:free_text]],
    search_ebook: [[:id_scoped]],
    search_ebook_query: [[:free_text]],
    search_audiobook: [[:id_scoped]],
    search_audiobook_query: [[:free_text]]
  }

  @sources [Prowlarr, Native]

  setup do
    ConfigCase.put_env(:indexer_adapters, %{newznab: IndexerAdapterMock})

    {:ok, _indexer} =
      Indexers.create(
        nil,
        %{name: "Native One", type: :newznab, base_url: "https://n.example", api_path: "/api"},
        %{"api_key" => "nzb-key-0123456789"}
      )

    :ok
  end

  # Each source's indexers answer with one row per query; the TVDB-scoped and the free-text query
  # of Prowlarr's `search_tv/3` return different links.
  defp answer(Prowlarr) do
    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      query = conn.query_params["query"]

      Req.Test.json(conn, [
        %{
          "title" => "Release #{query}",
          "downloadUrl" => "https://prowlarr.example/dl/#{URI.encode_www_form(query)}",
          "protocol" => "usenet",
          "indexerId" => 4,
          "indexer" => "Prowlarr Four"
        }
      ])
    end)
  end

  defp answer(Native) do
    stub(IndexerAdapterMock, :search, fn _indexer, query, _context ->
      {[
         %{
           title: "Release #{elem(query, 0)}",
           download_url: "https://n.example/dl/1",
           protocol: :usenet,
           query_origins: [origin(query)]
         }
       ], :asked}
    end)
  end

  defp fail(Prowlarr), do: Req.Test.stub(Cinder.ProwlarrStub, &Plug.Conn.send_resp(&1, 500, ""))

  defp fail(Native),
    do: stub(IndexerAdapterMock, :search, fn _i, _q, _c -> {[], {:failed, :timeout}} end)

  defp origin(query) do
    {_name, _args, origin} = List.keyfind(@callbacks, elem(query, 0), 0)
    origin
  end

  defp call(source, {name, args, _origin}), do: apply(source, name, args)

  defp rows({:ok, rows}), do: rows
  defp rows({:ok, rows, %Report{}}), do: rows

  for source <- @sources, {name, _args, _origin} = callback <- @callbacks do
    @source source
    @callback_spec callback

    test "#{inspect(source)}.#{name} answers rows that carry every required field" do
      answer(@source)
      result = call(@source, @callback_spec)

      assert match?({:ok, [_ | _]}, result) or match?({:ok, [_ | _], %Report{}}, result),
             inspect(result)

      for row <- rows(result) do
        assert is_binary(row.title) and String.trim(row.title) != ""
        assert is_binary(row.download_url) and row.download_url != ""
        assert row.protocol in [:usenet, :torrent]
        assert is_integer(row.indexer_id)
        assert is_binary(row.indexer_name) and row.indexer_name != ""
      end

      assert origins(result) == expected_origins(@source, @callback_spec)
    end

    test "#{inspect(source)}.#{name} answers an error when its indexers fail" do
      fail(@source)
      assert {:error, _reason} = call(@source, @callback_spec)
    end
  end

  test "Prowlarr's listed exception: every indexer down answers {:ok, []}" do
    Req.Test.stub(Cinder.ProwlarrStub, &Req.Test.json(&1, []))

    for callback <- @callbacks, do: assert(call(Prowlarr, callback) == {:ok, []})
  end

  # The query origins of the rows, in row order.
  defp origins(result), do: result |> rows() |> Enum.map(&Map.get(&1, :query_origins))

  defp expected_origins(Prowlarr, {name, _args, _origin}),
    do: Map.fetch!(@prowlarr_origins, name) || [nil]

  defp expected_origins(Native, {_name, _args, origin}), do: [[origin]]
end
