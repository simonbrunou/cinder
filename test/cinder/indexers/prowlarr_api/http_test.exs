defmodule Cinder.Indexers.ProwlarrApi.HTTPTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Cinder.Indexers.ProwlarrApi.{Connection, HTTP}
  alias Cinder.Test.RequestDeadlines

  @key "prowlarr-key-5d1e0c7a"
  @connection %Connection{url: "https://media.example.com/prowlarr", api_key: @key}

  # 4 MiB, the cap each read keeps.
  @cap 4_194_304

  # Answers every request with `fun.(conn)` and reports it to the test process.
  defp stub(fun) do
    test_pid = self()

    Req.Test.stub(Cinder.ProwlarrApiStub, fn conn ->
      send(
        test_pid,
        {:request, conn.method, conn.host, conn.request_path, conn.query_string,
         Plug.Conn.get_req_header(conn, "x-api-key")}
      )

      fun.(conn)
    end)
  end

  defp answer(conn, status, body, content_type \\ "application/json") do
    conn
    |> Plug.Conn.put_resp_content_type(content_type, "utf-8")
    |> Plug.Conn.send_resp(status, body)
  end

  test "a GET to the path under the base URL's own path, with the key as x-api-key" do
    stub(&answer(&1, 200, ~s([{"id": 1}])))

    assert {:ok, [%{"id" => 1}]} = HTTP.get(@connection, "/api/v1/indexer", [])

    assert_received {:request, "GET", "media.example.com", "/prowlarr/api/v1/indexer", "", [@key]}
  end

  test "the query reaches the request" do
    stub(&answer(&1, 200, "[]"))

    assert {:ok, []} = HTTP.get(@connection, "/api/v1/history", page: 2, pageSize: 50)

    assert_received {:request, "GET", _, "/prowlarr/api/v1/history", "page=2&pageSize=50", _}
  end

  test "a base URL's fragment is cut before the path is joined" do
    stub(&answer(&1, 200, "[]"))
    connection = %{@connection | url: "https://media.example.com/prowlarr#frag"}

    assert {:ok, []} = HTTP.get(connection, "/api/v1/indexer", [])
    assert_received {:request, "GET", _, "/prowlarr/api/v1/indexer", "", _}
  end

  test "a status other than 200 is {:http_status, status}, whatever its body under the cap" do
    for {status, body, type} <- [
          {401, "", "text/plain"},
          {500, ~s({"message": "boom"}), "application/json"},
          {500, "{not json", "application/json"},
          {404, "nope", "text/plain"}
        ] do
      stub(&answer(&1, status, body, type))

      assert {status, {:error, {:http_status, status}}} ==
               {status, HTTP.get(@connection, "/api/v1/indexer", [])}
    end
  end

  test "a redirect is not followed and is its status, sent once" do
    stub(fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://elsewhere.example/api/v1/indexer")
      |> Plug.Conn.send_resp(302, "")
    end)

    assert {:error, {:http_status, 302}} = HTTP.get(@connection, "/api/v1/indexer", [])
    assert_received {:request, "GET", "media.example.com", _, _, _}
    refute_received {:request, _, _, _, _, _}
  end

  test "a 500 is sent once, with no retry" do
    stub(&answer(&1, 500, ""))

    assert {:error, {:http_status, 500}} = HTTP.get(@connection, "/api/v1/indexer", [])
    assert_received {:request, _, _, _, _, _}
    refute_received {:request, _, _, _, _, _}
  end

  test "a 200 is decoded as JSON whatever its content type, and a body that is not JSON is :invalid_json" do
    stub(&answer(&1, 200, ~s({"proxyEnabled": false}), "text/plain"))
    assert {:ok, %{"proxyEnabled" => false}} = HTTP.get(@connection, "/api/v1/config/host", [])

    for body <- ["{not json", "", "<html></html>"] do
      stub(&answer(&1, 200, body))
      assert {body, {:error, :invalid_json}} == {body, HTTP.get(@connection, "/x", [])}
    end
  end

  test "a body of exactly the 4 MiB cap reads, and one byte more is :too_large" do
    at_cap = json_list_of_size(@cap)
    assert byte_size(at_cap) == @cap

    stub(&answer(&1, 200, at_cap))
    assert {:ok, list} = HTTP.get(@connection, "/api/v1/indexer", [])
    assert is_list(list)

    stub(&answer(&1, 200, at_cap <> " "))
    assert {:error, :too_large} = HTTP.get(@connection, "/api/v1/indexer", [])

    # Whatever its status.
    stub(&answer(&1, 500, at_cap <> " "))
    assert {:error, :too_large} = HTTP.get(@connection, "/api/v1/indexer", [])
  end

  test "each read runs under a 60 s deadline" do
    stub(&answer(&1, 200, "[]"))

    {_result, deadlines} =
      RequestDeadlines.capture(fn -> HTTP.get(@connection, "/api/v1/indexer", []) end)

    # The event names the request's own `url`, the path before the base URL's is joined.
    assert deadlines == [{"/api/v1/indexer", 60_000}]
  end

  test "a receive timeout is :timeout and another transport error :transport" do
    stub(&Req.Test.transport_error(&1, :timeout))
    assert {:error, :timeout} = HTTP.get(@connection, "/api/v1/indexer", [])

    stub(&Req.Test.transport_error(&1, :econnrefused))
    assert {:error, :transport} = HTTP.get(@connection, "/api/v1/indexer", [])
  end

  test "no error and no logged line holds the key, the URL or a body byte" do
    # The test env logs at :warning, and `with_log/2`'s level does not lower that, so these
    # modules log every level for this test: a debug line holding the key would show here.
    modules = [HTTP, Cinder.HTTPPolicy, Req.Steps, Req.Request]
    Logger.put_module_level(modules, :debug)
    on_exit(fn -> Logger.delete_module_level(modules) end)
    marker = "MARKER-77c2e1"

    answers = [
      # A 429 that echoes the key it received.
      fn conn ->
        [key] = Plug.Conn.get_req_header(conn, "x-api-key")
        answer(conn, 429, ~s({"message": "slow down #{key} #{marker}"}))
      end,
      &answer(&1, 500, marker, "text/plain"),
      &answer(&1, 302, marker, "text/plain"),
      &answer(&1, 200, "{#{marker} #{@key}"),
      &answer(&1, 200, :binary.copy(marker, 500_000)),
      &Req.Test.transport_error(&1, :econnrefused),
      &Req.Test.transport_error(&1, :timeout)
    ]

    for fun <- answers do
      stub(fun)

      {result, log} =
        with_log([level: :debug], fn -> HTTP.get(@connection, "/api/v1/indexer", []) end)

      assert {:error, _} = result
      text = inspect(result, limit: :infinity, printable_limit: :infinity) <> log

      for secret <- [@key, marker, "media.example.com", "/api/v1"] do
        refute text =~ secret, "#{inspect(secret)} in #{text}"
      end
    end
  end

  test "a connection's inspect shows no key" do
    refute inspect(@connection, limit: :infinity, printable_limit: :infinity) =~ @key
  end

  # A JSON list of objects exactly `size` bytes long.
  defp json_list_of_size(size) do
    item = ~s({"id": 1, "name": "#{String.duplicate("x", 1000)}"})
    count = div(size - 2, byte_size(item) + 1)
    body = "[" <> Enum.map_join(List.duplicate(item, count), ",", & &1) <> "]"
    pad = size - byte_size(body)
    "[" <> String.duplicate(" ", pad) <> binary_part(body, 1, byte_size(body) - 1)
  end
end
