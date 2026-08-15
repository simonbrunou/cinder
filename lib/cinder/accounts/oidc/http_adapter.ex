defmodule Cinder.Accounts.OIDC.HTTPAdapter do
  @moduledoc false

  alias Assent.HTTPAdapter
  alias Assent.HTTPAdapter.HTTPResponse
  alias Cinder.Accounts.OIDC
  alias Cinder.HTTPPolicy

  @behaviour HTTPAdapter

  @max_response_bytes 4 * 1024 * 1024
  @request_timeout_ms 20_000

  @impl HTTPAdapter
  def request(method, url, body, headers, req_options \\ []) do
    {source_origin, req_options} = Keyword.pop(req_options || [], :source_origin, url)
    {resolver, req_options} = Keyword.pop(req_options, :resolver)

    with true <- OIDC.secure_endpoint?(url),
         {:ok, target} <- request_target(url, source_origin, resolver) do
      options =
        [
          method: method,
          headers: headers ++ [HTTPAdapter.user_agent_header()],
          receive_timeout: 15_000,
          connect_options: [timeout: 5_000],
          retry: false,
          redirect: false
        ]
        |> maybe_put_body(body)
        |> Keyword.merge(req_options || [])
        |> then(&HTTPPolicy.request_options(target, &1))

      options
      |> Req.new()
      |> HTTPPolicy.bounded_request(@max_response_bytes, @request_timeout_ms)
      |> normalize_response()
    else
      false -> {:error, :https_required}
      error -> error
    end
  end

  defp request_target(url, source_origin, nil),
    do: HTTPPolicy.source_request_target(url, source_origin)

  defp request_target(url, source_origin, resolver) when is_function(resolver, 1),
    do: HTTPPolicy.source_request_target(url, source_origin, resolver)

  defp request_target(_url, _source_origin, _resolver), do: {:error, :invalid_resolver}

  defp maybe_put_body(options, nil), do: options
  defp maybe_put_body(options, body), do: Keyword.put(options, :body, body)

  defp normalize_response({:ok, response}) do
    headers =
      for {key, values} <- response.headers,
          value <- List.wrap(values) do
        {String.downcase(to_string(key), :ascii), to_string(value)}
      end

    {:ok,
     %HTTPResponse{
       status: response.status,
       headers: headers,
       body: response.body
     }}
  end

  defp normalize_response({:error, reason}), do: {:error, reason}
end
