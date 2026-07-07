defmodule Cinder.Subtitles.Provider.OpenSubtitles do
  @moduledoc """
  OpenSubtitles.com REST API v1 client. `search/1` needs only the Api-Key; `download/1` needs a
  JWT from `/login`, cached in `:persistent_term` and re-fetched once on a 401. Downloads consume
  a daily quota (20/day free) — a `406` surfaces as `{:error, :quota_exceeded}` so the caller can
  stop for the tick. `ponytail:` global token (single-instance app); id-based search only —
  moviehash is the sync-accuracy upgrade path.
  """
  @behaviour Cinder.Subtitles.Provider

  @default_base "https://api.opensubtitles.com/api/v1"
  @token_key {__MODULE__, :token}

  @impl true
  def search(criteria) do
    case request(:get, "/subtitles", params: search_params(criteria)) do
      {:ok, %{status: 200, body: %{"data" => data}}} -> {:ok, Enum.map(data, &normalize/1)}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def download(file_id), do: download(file_id, _retried? = false)

  @impl true
  def health do
    case request(:get, "/infos/formats", []) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- download with one re-login retry on 401 ---

  defp download(file_id, retried?) do
    with {:ok, token} <- token(),
         {:ok, %{status: 200, body: %{"link" => link}}} <-
           request(:post, "/download", json: %{file_id: file_id}, auth: token),
         {:ok, %{status: 200, body: body}} <- fetch(link) do
      {:ok, body}
    else
      {:ok, %{status: 401}} when not retried? ->
        :persistent_term.erase(@token_key)
        download(file_id, true)

      {:ok, %{status: 406}} ->
        {:error, :quota_exceeded}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- token cache ---

  defp token do
    case :persistent_term.get(@token_key, nil) do
      nil -> login()
      jwt -> {:ok, jwt}
    end
  end

  defp login do
    body = %{username: cfg(:username), password: cfg(:password)}

    case request(:post, "/login", json: body) do
      {:ok, %{status: 200, body: %{"token" => jwt}}} ->
        :persistent_term.put(@token_key, jwt)
        {:ok, jwt}

      {:ok, %{status: status}} ->
        {:error, {:login, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- request building ---

  defp search_params(criteria) do
    [
      imdb_id: imdb_number(criteria[:imdb_id]),
      parent_tmdb_id: (criteria[:season] && criteria[:tmdb_id]) || nil,
      tmdb_id: (is_nil(criteria[:season]) && criteria[:tmdb_id]) || nil,
      season_number: criteria[:season],
      episode_number: criteria[:episode],
      languages: criteria[:languages] |> List.wrap() |> Enum.join(",")
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
  end

  # OpenSubtitles wants the numeric imdb id (no "tt" prefix).
  defp imdb_number(nil), do: nil
  defp imdb_number("tt" <> digits), do: digits
  defp imdb_number(other), do: other

  defp normalize(%{"attributes" => a}) do
    %{
      file_id: a |> Map.get("files", []) |> List.first(%{}) |> Map.get("file_id"),
      language: a["language"],
      downloads: a["download_count"] || 0,
      hearing_impaired: a["hearing_impaired"] || false,
      ai_translated: a["ai_translated"] || false
    }
  end

  # A malformed entry (missing "attributes") degrades to a droppable result instead of
  # crashing the caller — a garbled provider response must never crash an import/sweep.
  defp normalize(_malformed) do
    %{file_id: nil, language: nil, downloads: 0, hearing_impaired: false, ai_translated: false}
  end

  # --- HTTP ---

  defp request(method, path, opts) do
    {auth, opts} = Keyword.pop(opts, :auth)

    Req.request(
      [
        method: method,
        url: base_url() <> path,
        headers: headers(auth)
      ] ++ Keyword.merge(req_options(), opts)
    )
  end

  defp fetch(link), do: Req.request([method: :get, url: link] ++ req_options())

  defp headers(auth) do
    base = [{"api-key", cfg(:api_key)}, {"user-agent", user_agent()}]
    if auth, do: [{"authorization", "Bearer " <> auth} | base], else: base
  end

  defp user_agent, do: "Cinder/#{Application.spec(:cinder, :vsn) || "dev"}"

  defp base_url, do: cfg(:base_url) || @default_base
  defp req_options, do: cfg(:req_options) || []

  defp cfg(field) do
    :cinder |> Application.get_env(__MODULE__, []) |> Keyword.get(field)
  end
end
