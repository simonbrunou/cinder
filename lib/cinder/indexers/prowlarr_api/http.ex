defmodule Cinder.Indexers.ProwlarrApi.HTTP do
  @moduledoc """
  The `Cinder.Indexers.ProwlarrApi` adapter: one GET to `<base URL><path>`, the base URL's own
  path kept and its fragment cut (`Cinder.HTTPPolicy.without_fragment/1`), with the key as
  `x-api-key`. It goes through `Cinder.HTTPPolicy.bounded_request/2` with a 4 MiB cap: in a
  throwaway Prowlarr 3.1.0.5799 container on 2026-11-26 (#1673), `/api/v1/indexer` with eight
  indexers answered 71,164 bytes. With the default options each read waits at most
  30 s for a chunk and 60 s in all; a `receive_timeout` in `req_options` replaces the 30 s, and
  one past 60 s is the whole read's deadline too (`bounded_request/2`).

  `redirect: false` and `retry: false` are set after the configured `req_options`, which cannot
  change them, so a 3xx is `{:http_status, status}` and each read is sent once. The adapter drops
  the answer's `content-type` before `bounded_request/2` reads it, so an error status whose body
  fits the cap keeps its status whatever that body holds, and decodes the body of a 200 itself:
  a body that is not JSON is `:invalid_json`. The deadline and the cap end a read as `:timeout`
  and `:too_large`, whatever its status, a receive timeout as `:timeout`, and any other failure
  as `:transport`. No error carries the URL, a header or a body byte.

  Config (`config :cinder, #{inspect(__MODULE__)}`): `req_options`, merged into each request
  (the test env routes them to a `Req.Test` stub).
  """

  @behaviour Cinder.Indexers.ProwlarrApi

  alias Cinder.HTTPPolicy
  alias Cinder.Indexers.ProwlarrApi.Connection

  @max_response_bytes 4 * 1024 * 1024
  @receive_timeout_ms 30_000

  @impl true
  def get(%Connection{url: url, api_key: api_key}, path, query) do
    [
      receive_timeout: @receive_timeout_ms,
      pool_timeout: 5_000,
      connect_options: [timeout: 5_000]
    ]
    |> Keyword.merge(req_options())
    |> Keyword.merge(
      method: :get,
      base_url: HTTPPolicy.without_fragment(url),
      url: path,
      params: query,
      headers: [{"x-api-key", api_key}],
      redirect: false,
      retry: false
    )
    |> Req.new()
    |> Req.Request.append_response_steps(raw_body: &drop_content_type/1)
    |> HTTPPolicy.bounded_request(@max_response_bytes)
    |> case do
      {:ok, %Req.Response{status: 200, body: body}} -> decode(body)
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, :request_timeout} -> {:error, :timeout}
      {:error, :response_too_large} -> {:error, :too_large}
      {:error, %Req.TransportError{reason: :timeout}} -> {:error, :timeout}
      {:error, _reason} -> {:error, :transport}
    end
  end

  defp req_options,
    do: :cinder |> Application.get_env(__MODULE__, []) |> Keyword.get(:req_options, [])

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp decode(_body), do: {:error, :invalid_json}

  # `HTTPPolicy.bounded_request/2` decodes a body labelled JSON before the status reaches this
  # adapter, and a malformed one would lose its status, so the label goes and `decode/1` reads
  # the body of a 200.
  defp drop_content_type({request, response}),
    do: {request, Req.Response.delete_header(response, "content-type")}
end
