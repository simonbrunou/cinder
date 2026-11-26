defmodule Cinder.Indexers.ProwlarrApi.HTTPBuiltRequestTest do
  # The request `Cinder.Indexers.ProwlarrApi.HTTP` builds, read through a Req `adapter:` that
  # records it, and a stored URL that does not parse, through the real adapter: the `Req.Test`
  # plug of the test config never parses the URL, and the request carries the key in
  # `x-api-key`, so no error, raise or log line may hold it.
  #
  # Not async: each test replaces the adapter's `req_options` for its run. No request leaves
  # the machine.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Cinder.ConfigCase
  alias Cinder.Indexers.ProwlarrApi.{Connection, HTTP}

  @key "prowlarr-key-built-request-71c4"

  # A Req adapter that sends the request it got to the test and answers 200 `[]`.
  defp recording_adapter do
    test_pid = self()

    fn request ->
      send(test_pid, {:built, request})
      {request, Req.Response.new(status: 200, body: "[]")}
    end
  end

  test "a read waits 30 s for a chunk, 5 s for a pooled or new connection, with no redirect or retry" do
    ConfigCase.put_env(HTTP, req_options: [adapter: recording_adapter()])

    assert {:ok, []} =
             HTTP.get(%Connection{url: "https://p.example", api_key: @key}, "/api/v1/indexer", [])

    assert_received {:built, request}

    assert Map.take(request.options, [:receive_timeout, :pool_timeout, :redirect, :retry]) == %{
             receive_timeout: 30_000,
             pool_timeout: 5_000,
             redirect: false,
             retry: false
           }

    assert request.options.connect_options == [timeout: 5_000]
  end

  test "req_options change the timeouts but never redirect or retry" do
    ConfigCase.put_env(HTTP,
      req_options: [
        adapter: recording_adapter(),
        receive_timeout: 1_000,
        redirect: true,
        retry: :transient
      ]
    )

    assert {:ok, []} =
             HTTP.get(%Connection{url: "https://p.example", api_key: @key}, "/api/v1/indexer", [])

    assert_received {:built, request}

    assert Map.take(request.options, [:receive_timeout, :redirect, :retry]) ==
             %{receive_timeout: 1_000, redirect: false, retry: false}
  end

  for url <- ["http://[bad", "not a url", ""] do
    @url url

    test "#{inspect(url)} as the base URL gives an error that holds no key" do
      ConfigCase.put_env(HTTP, req_options: [])

      {outcome, log} =
        with_log([level: :debug], fn ->
          try do
            HTTP.get(%Connection{url: @url, api_key: @key}, "/api/v1/indexer", [])
          rescue
            error -> {:raised, Exception.format(:error, error, __STACKTRACE__)}
          catch
            kind, reason -> {:caught, kind, reason}
          end
        end)

      text = inspect(outcome, limit: :infinity, printable_limit: :infinity) <> log
      refute text =~ @key, "the key in #{text}"
      assert {:error, _tag} = outcome
    end
  end
end
