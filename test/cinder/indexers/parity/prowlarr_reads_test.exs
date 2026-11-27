defmodule Cinder.Indexers.Parity.ProwlarrReadsTest do
  use ExUnit.Case, async: true

  import Mox

  alias Cinder.Indexers.Parity.ProwlarrReads
  alias Cinder.Indexers.ProwlarrApi.{Connection, HTTP}

  @key "SYNTHETICKEY123"
  @connection %Connection{url: "https://media.example.com/prowlarr", api_key: @key}
  @from ~U[2026-11-25 10:00:00Z]
  @to ~U[2026-11-25 12:00:00Z]

  # Every read goes through the real HTTP adapter, which sends it to the `Req.Test` stub.
  setup do
    stub_with(Cinder.Indexers.ProwlarrApiMock, HTTP)
    :ok
  end

  # Answers each request with `fun.(conn)` and reports its path and query to the test process.
  defp stub(fun) do
    test_pid = self()

    Req.Test.stub(Cinder.ProwlarrApiStub, fn conn ->
      send(test_pid, {:request, conn.request_path, conn.query_string})
      fun.(conn)
    end)
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json", "utf-8")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp entry(id, indexer_id, date, opts \\ []) do
    %{
      "id" => id,
      "indexerId" => indexer_id,
      "date" => date,
      "downloadId" => nil,
      "successful" => Keyword.get(opts, :successful, true),
      "eventType" => Keyword.get(opts, :event_type, "indexerQuery"),
      "data" =>
        Map.merge(
          %{
            "query" => "Dune 2021",
            "queryType" => "search",
            "categories" => "2000",
            "source" => "Prowlarr",
            "host" => "media.example.com",
            "queryResults" => Keyword.get(opts, :results, "12"),
            "url" => "https://indexer.example/api?t=search&apikey=#{@key}&r=#{@key}",
            "elapsedTime" => "300",
            "cached" => "0"
          },
          Keyword.get(opts, :data, %{})
        )
    }
  end

  defp page(page, page_size, total, records),
    do: %{
      "page" => page,
      "pageSize" => page_size,
      "sortKey" => "date",
      "sortDirection" => "descending",
      "totalRecords" => total,
      "records" => records
    }

  defp query(conn), do: URI.query_decoder(conn.query_string) |> Enum.to_list()

  describe "history/3" do
    test "asks for indexer queries of the mapped indexers, page by page, and keeps the window's entries without their Url" do
      stub(fn conn ->
        case List.keyfind(query(conn), "page", 0) do
          {"page", "1"} ->
            json(
              conn,
              200,
              page(1, 500, 1200, [
                entry(9, 3, "2026-11-25T12:30:00Z"),
                entry(8, 3, "2026-11-25T11:00:00Z",
                  results: "7",
                  data: %{
                    "cached" => "1",
                    "query" => "",
                    "queryType" => "tvsearch",
                    "categories" => "",
                    "tvdbId" => "76885",
                    "season" => "1",
                    "limit" => "100"
                  }
                )
              ])
            )

          {"page", "2"} ->
            json(
              conn,
              200,
              page(2, 500, 1200, [
                entry(7, 5, "2026-11-25T10:00:00Z",
                  successful: false,
                  results: "",
                  data: %{"categories" => "2000,5070", "offset" => "100"}
                ),
                entry(6, 5, "2026-11-25T09:59:59Z")
              ])
            )
        end
      end)

      assert {:ok, entries} = ProwlarrReads.history(@connection, [3, 5], {@from, @to})

      assert entries == [
               %{
                 id: 8,
                 indexer_id: 3,
                 date: ~U[2026-11-25 11:00:00Z],
                 successful: true,
                 query_results: 7,
                 cached: true,
                 query: "",
                 query_type: "tvsearch",
                 categories: [],
                 ids: %{"tvdbId" => "76885", "season" => "1"},
                 source: "Prowlarr",
                 paging: %{"limit" => "100"}
               },
               %{
                 id: 7,
                 indexer_id: 5,
                 date: ~U[2026-11-25 10:00:00Z],
                 successful: false,
                 query_results: nil,
                 cached: false,
                 query: "Dune 2021",
                 query_type: "search",
                 categories: [2000, 5070],
                 ids: %{},
                 source: "Prowlarr",
                 paging: %{"offset" => "100"}
               }
             ]

      assert_received {:request, "/prowlarr/api/v1/history", first}
      assert first == "eventType=2&indexerIds=3&indexerIds=5&page=1&pageSize=500"
      assert_received {:request, "/prowlarr/api/v1/history", second}
      assert second == "eventType=2&indexerIds=3&indexerIds=5&page=2&pageSize=500"
      refute_received {:request, _, _}

      refute inspect(entries, limit: :infinity, printable_limit: :infinity) =~ @key
      refute inspect(entries, limit: :infinity, printable_limit: :infinity) =~ "indexer.example"
      refute inspect(entries, limit: :infinity, printable_limit: :infinity) =~ "media.example.com"
    end

    test "stops at the page that reaches totalRecords, and at an empty page" do
      # 1,000 records in all: page 2 of 500 reaches them, though its oldest is inside the window.
      stub(fn conn ->
        {"page", n} = List.keyfind(query(conn), "page", 0)

        json(
          conn,
          200,
          page(String.to_integer(n), 500, 1000, [
            entry(100 - String.to_integer(n), 3, "2026-11-25T11:00:00Z")
          ])
        )
      end)

      assert {:ok, [%{id: 99}, %{id: 98}]} = ProwlarrReads.history(@connection, [3], {@from, @to})
      assert_received {:request, _, "eventType=2&indexerIds=3&page=1&pageSize=500"}
      assert_received {:request, _, "eventType=2&indexerIds=3&page=2&pageSize=500"}
      refute_received {:request, _, _}

      stub(&json(&1, 200, page(1, 500, 5000, [])))
      assert {:ok, []} = ProwlarrReads.history(@connection, [3], {@from, @to})
      assert_received {:request, _, _}
      refute_received {:request, _, _}
    end

    test "an entry seen on two pages, pushed down by a newer query, is kept once" do
      stub(fn conn ->
        case List.keyfind(query(conn), "page", 0) do
          {"page", "1"} ->
            json(conn, 200, page(1, 500, 1200, [entry(8, 3, "2026-11-25T11:00:00Z")]))

          {"page", "2"} ->
            json(
              conn,
              200,
              page(2, 500, 1201, [
                entry(8, 3, "2026-11-25T11:00:00Z"),
                entry(2, 3, "2026-11-24T11:00:00Z")
              ])
            )
        end
      end)

      assert {:ok, [%{id: 8}]} = ProwlarrReads.history(@connection, [3], {@from, @to})
    end

    test "reads 20 pages, and a window that needs a 21st is :too_many_pages" do
      inside = fn conn ->
        {"page", n} = List.keyfind(query(conn), "page", 0)
        n = String.to_integer(n)
        json(conn, 200, page(n, 500, 100_000, [entry(1000 - n, 3, "2026-11-25T11:00:00Z")]))
      end

      stub(inside)
      assert {:error, :too_many_pages} = ProwlarrReads.history(@connection, [3], {@from, @to})

      for n <- 1..20 do
        assert_received {:request, _, query}
        assert query =~ "page=#{n}&"
      end

      refute_received {:request, _, _}

      # The 20th page ends the read when its oldest entry is before the window.
      stub(fn conn ->
        case List.keyfind(query(conn), "page", 0) do
          {"page", "20"} ->
            json(conn, 200, page(20, 500, 100_000, [entry(1, 3, "2026-11-24T11:00:00Z")]))

          _page ->
            inside.(conn)
        end
      end)

      assert {:ok, entries} = ProwlarrReads.history(@connection, [3], {@from, @to})
      assert length(entries) == 19
    end

    test "a page not sorted newest first is :unexpected_response" do
      stub(
        &json(
          &1,
          200,
          page(1, 500, 2, [
            entry(1, 3, "2026-11-25T10:30:00Z"),
            entry(2, 3, "2026-11-25T11:00:00Z")
          ])
        )
      )

      assert {:error, :unexpected_response} =
               ProwlarrReads.history(@connection, [3], {@from, @to})
    end

    test "an entry with a field renamed, missing or of another type fails the whole read" do
      good = entry(5, 3, "2026-11-25T11:00:00Z")

      bad = [
        Map.delete(good, "indexerId"),
        good |> Map.delete("indexerId") |> Map.put("indexerID", 3),
        Map.put(good, "indexerId", "3"),
        Map.delete(good, "id"),
        Map.delete(good, "date"),
        Map.put(good, "date", "2026-11-25T11:00:00"),
        Map.put(good, "date", "yesterday"),
        Map.delete(good, "successful"),
        Map.put(good, "successful", "true"),
        Map.put(good, "eventType", "releaseGrabbed"),
        Map.put(good, "eventType", 2),
        Map.delete(good, "data"),
        Map.put(good, "data", nil),
        put_in(good, ["data", "queryResults"], 12),
        put_in(good, ["data", "queryResults"], "twelve"),
        put_in(good, ["data", "queryResults"], "-1"),
        update_in(good, ["data"], &Map.delete(&1, "queryResults")),
        put_in(good, ["data", "cached"], "true"),
        put_in(good, ["data", "cached"], 1),
        update_in(good, ["data"], &Map.delete(&1, "cached")),
        update_in(good, ["data"], &Map.delete(&1, "query")),
        put_in(good, ["data", "query"], nil),
        update_in(good, ["data"], &Map.delete(&1, "queryType")),
        put_in(good, ["data", "queryType"], 2),
        update_in(good, ["data"], &Map.delete(&1, "categories")),
        put_in(good, ["data", "categories"], 2000),
        put_in(good, ["data", "categories"], "2000,"),
        put_in(good, ["data", "categories"], "2000, 5070"),
        put_in(good, ["data", "categories"], "movies"),
        put_in(good, ["data", "tvdbId"], 76_885),
        put_in(good, ["data", "season"], nil),
        put_in(good, ["data", "author"], ["Philip K. Dick"]),
        update_in(good, ["data"], &Map.delete(&1, "source")),
        put_in(good, ["data", "source"], nil),
        put_in(good, ["data", "limit"], 100),
        put_in(good, ["data", "offset"], nil)
      ]

      for record <- bad, records <- [[record], [good, record]] do
        stub(&json(&1, 200, page(1, 500, length(records), records)))

        assert {record, {:error, :unexpected_response}} ==
                 {record, ProwlarrReads.history(@connection, [3], {@from, @to})}
      end

      for body <- [
            [],
            %{"records" => []},
            %{"totalRecords" => 1},
            %{"totalRecords" => "1", "records" => []},
            %{"totalRecords" => -1, "records" => []}
          ] do
        stub(&json(&1, 200, body))

        assert {body, {:error, :unexpected_response}} ==
                 {body, ProwlarrReads.history(@connection, [3], {@from, @to})}
      end

      # The control: the same good entry alone reads.
      stub(&json(&1, 200, page(1, 500, 1, [good])))
      assert {:ok, [%{id: 5}]} = ProwlarrReads.history(@connection, [3], {@from, @to})
    end

    test "a 401, a 302 and a body over the 4 MiB cap each return a closed tag" do
      stub(&json(&1, 401, %{"message" => "key #{@key}"}))
      assert {:error, {:http_status, 401}} = ProwlarrReads.history(@connection, [3], {@from, @to})

      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://elsewhere.example/?apikey=#{@key}")
        |> Plug.Conn.send_resp(302, "")
      end)

      assert {:error, {:http_status, 302}} = ProwlarrReads.history(@connection, [3], {@from, @to})

      big = String.duplicate("x", 4 * 1024 * 1024)

      stub(
        &json(
          &1,
          200,
          page(1, 500, 1, [entry(1, 3, "2026-11-25T11:00:00Z", data: %{"pad" => big})])
        )
      )

      assert {:error, :too_large} = ProwlarrReads.history(@connection, [3], {@from, @to})
    end

    test "no indexer id sends no request" do
      stub(&json(&1, 200, page(1, 500, 0, [])))
      assert {:ok, []} = ProwlarrReads.history(@connection, [], {@from, @to})
      refute_received {:request, _, _}
    end
  end

  describe "status/1" do
    test "an indexer in backoff parses to its id, its backoff's end and its latest failure" do
      stub(
        &json(&1, 200, [
          %{
            "id" => 1,
            "indexerId" => 4,
            "disabledTill" => "2026-11-25T13:00:00Z",
            "mostRecentFailure" => "2026-11-25T11:00:00Z",
            "initialFailure" => "2026-11-25T10:00:00Z"
          },
          %{"id" => 2, "indexerId" => 5, "disabledTill" => "2026-11-25T14:00:00Z"}
        ])
      )

      assert {:ok,
              [
                %{
                  indexer_id: 4,
                  disabled_till: ~U[2026-11-25 13:00:00Z],
                  most_recent_failure: ~U[2026-11-25 11:00:00Z]
                },
                %{
                  indexer_id: 5,
                  disabled_till: ~U[2026-11-25 14:00:00Z],
                  most_recent_failure: nil
                }
              ]} == ProwlarrReads.status(@connection)

      assert_received {:request, "/prowlarr/api/v1/indexerstatus", ""}
    end

    test "no indexer in backoff is an empty list, and a malformed answer :unexpected_response" do
      stub(&json(&1, 200, []))
      assert {:ok, []} = ProwlarrReads.status(@connection)

      for body <- [
            %{},
            [%{"indexerID" => 4}],
            [%{"indexerId" => 4, "disabledTill" => "soon"}],
            [%{"indexerId" => 4, "mostRecentFailure" => 5}],
            [%{"indexerId" => "4", "disabledTill" => "2026-11-25T14:00:00Z"}],
            # Prowlarr lists only indexers in backoff, each with its end: a record without one
            # would read as no backoff.
            [%{"indexerId" => 4}],
            [%{"indexerId" => 4, "disabledTill" => nil}],
            [%{"indexerId" => 4, "disabledtill" => "2026-11-25T14:00:00Z"}]
          ] do
        stub(&json(&1, 200, body))
        assert {body, {:error, :unexpected_response}} == {body, ProwlarrReads.status(@connection)}
      end
    end

    test "an error status is its closed tag" do
      stub(&json(&1, 500, %{"message" => @key}))
      assert {:error, {:http_status, 500}} = ProwlarrReads.status(@connection)
    end
  end
end
