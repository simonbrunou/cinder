defmodule Cinder.Acquisition.IndexerTest do
  # `Cinder.Acquisition.Indexer.request/3`, the request every per-type adapter sends (#1651): its
  # budget, and the closed tag each way it can fail.
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.Indexer
  alias Cinder.Test.{RequestDeadlines, SilentServer}

  defp context(left_ms), do: %{deadline_at: System.monotonic_time(:millisecond) + left_ms}

  defp stubbed(fun) do
    Req.Test.stub(__MODULE__, fun)
    [url: "https://indexer.example/api", plug: {Req.Test, __MODULE__}]
  end

  defp respond(conn, {:transport, reason}), do: Req.Test.transport_error(conn, reason)

  defp respond(conn, :oversized),
    do: Plug.Conn.send_resp(conn, 200, String.duplicate("x", 4_194_305))

  defp respond(conn, :bad_json) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, "{apikey=secret")
  end

  describe "the budget" do
    test "is the 30 s own timeout when 90 s are left" do
      options = stubbed(&Plug.Conn.send_resp(&1, 200, "ok"))

      assert {{:ok, %Req.Response{status: 200}}, [{"/api", 30_000}]} =
               RequestDeadlines.capture(fn -> Indexer.request(context(90_000), options) end)
    end

    test "is the time left when that is shorter than the own timeout" do
      options = stubbed(&Plug.Conn.send_resp(&1, 200, "ok"))

      assert {{:ok, _response}, [{"/api", deadline_ms}]} =
               RequestDeadlines.capture(fn -> Indexer.request(context(10_000), options) end)

      assert deadline_ms in 9_000..10_000
    end

    test "with no time left sends nothing and reads as the deadline" do
      options = stubbed(fn _conn -> flunk("sent") end)

      for left_ms <- [0, -5_000] do
        assert {{:error, :deadline}, []} =
                 RequestDeadlines.capture(fn -> Indexer.request(context(left_ms), options) end)
      end
    end
  end

  describe "a request against a socket that never answers" do
    # The match is the check: each tag names which bound ended the request. The elapsed bound only
    # keeps the call well under the 30 s own timeout (testing.md, the `SilentServer` bullet).
    test "ends at its own timeout with more time left, as a timeout" do
      started = System.monotonic_time(:millisecond)

      assert {:error, :timeout} =
               Indexer.request(context(90_000), [url: SilentServer.start!()], timeout_ms: 200)

      assert System.monotonic_time(:millisecond) - started < 15_000
    end

    test "with less time left than its own timeout, is cut by the deadline" do
      started = System.monotonic_time(:millisecond)

      assert {:error, :deadline} = Indexer.request(context(200), url: SilentServer.start!())
      assert System.monotonic_time(:millisecond) - started < 15_000
    end
  end

  describe "an error" do
    test "a timeout that comes before the deadline is the request's own" do
      options = stubbed(&Req.Test.transport_error(&1, :timeout))

      assert {:error, :timeout} = Indexer.request(context(10_000), options)
    end

    for {name, answer, tag} <- [
          {"an unknown host", {:transport, :nxdomain}, :dns},
          {"a refused connection", {:transport, :econnrefused}, :connection_refused},
          {"any other transport error", {:transport, :closed}, :connection_failed},
          {"a body one byte over the 4 MiB cap", :oversized, :too_large},
          {"a JSON body that does not decode", :bad_json, :bad_response}
        ] do
      @answer answer
      @tag_name tag

      test "#{name} reads #{tag}" do
        options = stubbed(&respond(&1, @answer))
        assert Indexer.request(context(90_000), options) == {:error, @tag_name}
      end
    end

    test "a body of exactly the 4 MiB cap comes back" do
      options = stubbed(&Plug.Conn.send_resp(&1, 200, String.duplicate("x", 4_194_304)))
      assert {:ok, %Req.Response{status: 200}} = Indexer.request(context(90_000), options)
    end

    test "a status of its own comes back as a response for the adapter to judge" do
      assert {:ok, %Req.Response{status: 503}} =
               Indexer.request(context(90_000), stubbed(&Plug.Conn.send_resp(&1, 503, "")))
    end

    test "follows no redirect" do
      options =
        stubbed(fn conn ->
          conn
          |> Plug.Conn.put_resp_header("location", "https://elsewhere.example/")
          |> Plug.Conn.send_resp(302, "")
        end)

      assert {:ok, %Req.Response{status: 302}} = Indexer.request(context(90_000), options)
    end
  end
end
