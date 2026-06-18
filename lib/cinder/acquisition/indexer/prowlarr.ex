defmodule Cinder.Acquisition.Indexer.Prowlarr do
  @moduledoc """
  Real `Cinder.Acquisition.Indexer` impl, backed by `Req`, against Prowlarr's
  unified JSON search (`GET /api/v1/search`).

  Reads `base_url`, `api_key` and optional `req_options` from
  `config :cinder, #{inspect(__MODULE__)}` at runtime. Searches by IMDb id with
  Prowlarr's `{ImdbId:...}` query token (`type=movie`) and returns normalized
  release maps (`%{title, size, download_url, seeders}`). `download_url` falls back
  to a magnet link when no torrent-file URL is present.
  """
  @behaviour Cinder.Acquisition.Indexer

  @default_base_url "http://localhost:9696"

  @impl true
  def search(imdb_id) do
    params = [query: "{ImdbId:#{imdb_id}}", type: "movie"]

    case request(url: "/api/v1/search", params: params) do
      {:ok, %{status: 200, body: results}} when is_list(results) ->
        {:ok, Enum.map(results, &normalize/1)}

      {:ok, %{status: 200}} ->
        {:error, :unexpected_response}

      other ->
        error(other)
    end
  end

  defp request(opts) do
    config = Application.get_env(:cinder, __MODULE__, [])

    [base_url: Keyword.get(config, :base_url, @default_base_url)]
    |> auth(Keyword.get(config, :api_key))
    |> Keyword.merge(opts)
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Req.new()
    |> Req.request()
  end

  defp auth(opts, nil), do: opts
  defp auth(opts, api_key), do: Keyword.put(opts, :headers, [{"x-api-key", api_key}])

  defp error({:ok, %{status: status}}), do: {:error, {:prowlarr_status, status}}
  defp error({:error, reason}), do: {:error, reason}

  defp normalize(result) do
    %{
      title: result["title"],
      size: result["size"],
      download_url: result["downloadUrl"] || result["magnetUrl"],
      seeders: result["seeders"]
    }
  end
end
