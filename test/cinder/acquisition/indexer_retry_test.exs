defmodule Cinder.Acquisition.IndexerRetryTest do
  # The one retry of `Cinder.Acquisition.Indexer.request/3` (#1654, #1619 point 2): HTTP 502, 503,
  # 504 and 408 get one more request after 2 s, inside the search deadline, and only the retry's
  # answer counts. Not async: the retry delay is `Cinder.Acquisition.Indexer`'s global config,
  # which `config/test.exs` shortens and the 2 s case unsets.
  use ExUnit.Case, async: false

  alias Cinder.Acquisition.Indexer
  alias Cinder.ConfigCase

  defp context(left_ms), do: %{deadline_at: System.monotonic_time(:millisecond) + left_ms}

  # A stub answering each request with the next status of `statuses`, the last one again once
  # they run out, and telling the test process the monotonic time of each request.
  defp answering(statuses) do
    test_pid = self()
    {:ok, left} = Agent.start_link(fn -> statuses end)

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:request, System.monotonic_time(:millisecond)})

      status =
        Agent.get_and_update(left, fn
          [status] -> {status, [status]}
          [status | rest] -> {status, rest}
        end)

      Plug.Conn.send_resp(conn, status, "")
    end)

    [url: "https://indexer.example/api", plug: {Req.Test, __MODULE__}]
  end

  defp request_times do
    receive do
      {:request, at} -> [at | request_times()]
    after
      0 -> []
    end
  end

  test "waits 2 s by default, the value the app runs with, and only the retry's answer counts" do
    ConfigCase.put_env(Indexer, [])
    options = answering([502, 200])

    assert {:ok, %Req.Response{status: 200}} = Indexer.request(context(90_000), options)
    assert [first, second] = request_times()
    assert (second - first) in 2_000..2_999
  end

  test "sends one retry only: a second 502 is the answer" do
    options = answering([502, 502, 200])

    assert {:ok, %Req.Response{status: 502}} = Indexer.request(context(90_000), options)
    assert length(request_times()) == 2
  end

  test "retries 502, 503, 504 and 408, and sends every other status once" do
    for status <- [502, 503, 504, 408] do
      options = answering([status, 200])
      assert {status, {:ok, %Req.Response{status: 200}}} == {status, strip(options)}
      assert {status, length(request_times())} == {status, 2}
    end

    for status <- [500, 501, 505, 429, 401, 404, 410, 403, 302, 200] do
      options = answering([status, 200])

      assert {status, {:ok, %Req.Response{status: status}}} == {status, strip(options)}
      assert {status, length(request_times())} == {status, 1}
    end
  end

  test "retries no refused connection" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:request, System.monotonic_time(:millisecond)})
      Req.Test.transport_error(conn, :econnrefused)
    end)

    options = [url: "https://indexer.example/api", plug: {Req.Test, __MODULE__}]
    assert Indexer.request(context(90_000), options) == {:error, :connection_refused}
    assert length(request_times()) == 1
  end

  # The 2 s delay outlasts the 1.5 s left, so the retry is never sent and reads as the deadline.
  test "a retry the deadline would cut is not sent and reads as the deadline" do
    ConfigCase.put_env(Indexer, [])
    options = answering([503, 200])

    assert Indexer.request(context(1_500), options) == {:error, :deadline}
    assert length(request_times()) == 1
  end

  # It answers at once: waiting out the 2 s delay would hold the search past its deadline.
  test "a retry the deadline would cut answers without waiting the delay" do
    ConfigCase.put_env(Indexer, [])
    options = answering([503, 200])
    started = System.monotonic_time(:millisecond)

    assert Indexer.request(context(300), options) == {:error, :deadline}
    assert System.monotonic_time(:millisecond) - started < 1_000
  end

  defp strip(options) do
    case Indexer.request(context(90_000), options) do
      {:ok, %Req.Response{status: status}} -> {:ok, %Req.Response{status: status}}
      other -> other
    end
  end
end
