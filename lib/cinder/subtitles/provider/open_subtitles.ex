defmodule Cinder.Subtitles.Provider.OpenSubtitles do
  @moduledoc """
  OpenSubtitles.com REST API v1 client. `search/1` needs only the Api-Key; `download/1` needs a
  JWT from `/login`, cached in `:persistent_term` and re-fetched once on a 401. Downloads consume
  a daily quota (20/day free) — a `406` surfaces as `{:error, :quota_exceeded}` so the caller can
  stop for the tick. `ponytail:` global token (single-instance app). `search/1` sends the imdb/tmdb
  id plus the file's `moviehash` when available; OpenSubtitles returns the id-matched candidates and
  flags the hash-synced ones via `moviehash_match` (it does not narrow the result set), which
  `Cinder.Subtitles` prefers.
  """
  @behaviour Cinder.Subtitles.Provider

  alias Cinder.HTTPPolicy

  @default_base "https://api.opensubtitles.com/api/v1"
  @token_key {__MODULE__, :token}

  # Bounded so a hung/blackholed OpenSubtitles can't stall the (synchronous) import/sweep call
  # sites. health/0 gets the repo's 3s connect+receive probe convention (matches
  # Prowlarr/Jellyfin/Discord); search/download/login/the external download link get a longer
  # timeout since they carry an actual request/response body.
  @health_timeout [receive_timeout: 3_000, connect_options: [timeout: 3_000]]
  @data_timeout [
    receive_timeout: 15_000,
    pool_timeout: 5_000,
    connect_options: [timeout: 5_000]
  ]
  @max_api_response_bytes 4 * 1024 * 1024
  @max_subtitle_bytes 10 * 1024 * 1024
  @max_redirects 5
  @untrusted_req_option_keys [
    :plug,
    :finch,
    :finch_request,
    :connect_options,
    :pool_timeout,
    :receive_timeout,
    :inet6,
    :unix_socket,
    :pool_max_idle_time
  ]

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
    # POST /login validates the Api-Key (header) AND username/password (body) in one call, so a green
    # health row means downloads will actually work — not just that the key is shaped right. Doesn't
    # cache the token (the real download path's login/0 owns the cache).
    body = %{username: cfg(:username), password: cfg(:password)}

    case request(:post, "/login", [json: body], @health_timeout) do
      {:ok, %{status: 200, body: %{"token" => _}}} -> :ok
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
      moviehash: criteria[:moviehash],
      languages: criteria[:languages] |> List.wrap() |> Enum.join(",")
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    # The API 301-canonicalizes non-alphabetical param order (issue #142); emitting sorted
    # skips a redirect round-trip per search.
    |> Enum.sort()
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
      ai_translated: a["ai_translated"] || false,
      moviehash_match: a["moviehash_match"] || false
    }
  end

  # A malformed entry (missing "attributes") degrades to a droppable result instead of
  # crashing the caller — a garbled provider response must never crash an import/sweep.
  defp normalize(_malformed) do
    %{
      file_id: nil,
      language: nil,
      downloads: 0,
      hearing_impaired: false,
      ai_translated: false,
      moviehash_match: false
    }
  end

  # --- HTTP ---

  defp request(method, path, opts, timeout \\ @data_timeout) do
    {auth, opts} = Keyword.pop(opts, :auth)

    base =
      [method: method, url: base_url() <> path, headers: headers(auth)] ++ timeout

    request =
      req_options()
      |> Req.new()
      |> Req.merge(base ++ opts)
      |> Req.merge(auth: nil, redirect: false)

    run_request(request, @max_redirects)
  end

  # The configured API host can answer with a 3xx (a stale/moved base URL, or a canonicalizing
  # redirect on the host itself) — a Location-bearing redirect is a hop to follow, not a fetch
  # failure, bounded exactly like the untrusted subtitle-link redirect below. Only a *same-origin*
  # hop is followed: this request carries the Api-Key/Bearer token, and a cross-origin redirect is
  # left alone (surfaces as the ordinary HTTP-status error below) so a spoofed/compromised
  # redirect can't walk off with the credentials — see the "does not forward ... across redirects"
  # tests.
  defp run_request(request, redirects_left) do
    case HTTPPolicy.bounded_request(request, @max_api_response_bytes) do
      {:ok, %{status: status} = response} when status in [301, 302, 303, 307, 308] ->
        follow_api_redirect(request, response, redirects_left)

      result ->
        result
    end
  end

  defp follow_api_redirect(_request, _response, 0), do: {:error, :too_many_redirects}

  defp follow_api_redirect(request, response, redirects_left) do
    with [location | _] <- Req.Response.get_header(response, "location"),
         {:ok, next_uri} <- HTTPPolicy.resolve_redirect(request.url, location, :same_origin) do
      # A Location URL is complete as-is: keeping the original `params:` option would re-append
      # them onto it, turning a canonicalizing 301 into an infinite loop (issue #142).
      request = Req.Request.delete_option(request, :params)
      run_request(Req.merge(request, url: next_uri), redirects_left - 1)
    else
      _ -> {:ok, response}
    end
  end

  defp fetch(link) do
    with {:ok, uri} <- validate_url(link) do
      fetch_subtitle(uri, @max_redirects)
    end
  end

  defp fetch_subtitle(uri, redirects_left) do
    request =
      [method: :get, url: uri, redirect: false]
      |> Keyword.merge(@data_timeout)
      |> Keyword.merge(untrusted_req_options())
      |> Keyword.put(:retry, false)
      |> Keyword.put(:redirect, false)
      |> Req.new()

    case HTTPPolicy.bounded_request(request, @max_subtitle_bytes) do
      {:ok, %{status: status} = response} when status in [301, 302, 303, 307, 308] ->
        follow_subtitle_redirect(uri, response, redirects_left)

      result ->
        result
    end
  end

  defp follow_subtitle_redirect(_uri, _response, 0), do: {:error, :too_many_redirects}

  defp follow_subtitle_redirect(uri, response, redirects_left) do
    case Req.Response.get_header(response, "location") do
      [location | _] ->
        with {:ok, next} <- resolve_redirect(uri, location) do
          fetch_subtitle(next, redirects_left - 1)
        end

      [] ->
        {:ok, response}
    end
  end

  defp headers(auth) do
    base = [{"api-key", cfg(:api_key)}, {"user-agent", user_agent()}]
    if auth, do: [{"authorization", "Bearer " <> auth} | base], else: base
  end

  defp user_agent, do: "Cinder/#{Application.spec(:cinder, :vsn) || "dev"}"

  defp base_url, do: cfg(:base_url) || @default_base
  defp req_options, do: cfg(:req_options) || []
  defp untrusted_req_options, do: Keyword.take(req_options(), @untrusted_req_option_keys)

  defp validate_url(url) do
    case cfg(:url_resolver) do
      resolver when is_function(resolver, 1) -> HTTPPolicy.validate_untrusted_url(url, resolver)
      nil -> HTTPPolicy.validate_untrusted_url(url)
    end
  end

  defp resolve_redirect(current, location) do
    case cfg(:url_resolver) do
      resolver when is_function(resolver, 1) ->
        HTTPPolicy.resolve_redirect(current, location, resolver)

      nil ->
        HTTPPolicy.resolve_redirect(current, location, :untrusted)
    end
  end

  defp cfg(field) do
    :cinder |> Application.get_env(__MODULE__, []) |> Keyword.get(field)
  end
end
