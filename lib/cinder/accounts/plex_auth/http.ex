defmodule Cinder.Accounts.PlexAuth.HTTP do
  @moduledoc """
  Real `Cinder.Accounts.PlexAuth` impl, backed by `Req`, against plex.tv's
  PIN-based OAuth API: create/check a PIN (`/api/v2/pins`), fetch the signed-in
  account (`/api/v2/user`), and list the servers it can reach (`/api/v2/resources`).
  `server_machine_id/0` instead hits the configured local Plex server's
  unauthenticated `/identity`, and `watchlist/1` hits the account-level discover
  host (`https://discover.provider.plex.tv`).

  Reads `req_options` from `config :cinder, #{inspect(__MODULE__)}`; the local
  server's `url` comes from `config :cinder, Cinder.Library.MediaServer.Plex` (the
  same key the media-server impl reads). Validated against live plex.tv only at dogfood.
  """
  @behaviour Cinder.Accounts.PlexAuth

  alias Cinder.Accounts.PlexAuth
  alias Cinder.HTTPPolicy

  @max_response_bytes 4 * 1024 * 1024
  @base_url "https://plex.tv"
  # The watchlist is account state, served by plex.tv's discover host rather than the
  # /api/v2 surface the sign-in calls use.
  @discover_base_url "https://discover.provider.plex.tv"
  # One page is the whole watchlist for a household; plex.tv caps the page size anyway.
  @watchlist_page_size 500

  @impl true
  def create_pin do
    request(:post, "/api/v2/pins", params: [strong: true])
    |> result()
    |> case do
      {:ok, %{"id" => id, "code" => code}} -> {:ok, %{id: id, code: code}}
      {:ok, _other} -> {:error, :unexpected_response}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def check_pin(id) do
    request(:get, "/api/v2/pins/#{id}")
    |> result()
    |> case do
      {:ok, %{"authToken" => token}} when is_binary(token) and token != "" -> {:ok, token}
      {:ok, _pending} -> {:error, :pending}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def account(token) do
    request(:get, "/api/v2/user", headers: [{"x-plex-token", token}])
    |> result()
    |> case do
      {:ok, %{} = body} ->
        {:ok, %{id: body["id"], email: body["email"], username: body["username"]}}

      {:ok, _other} ->
        {:error, :unexpected_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def server_ids(token) do
    request(:get, "/api/v2/resources",
      headers: [{"x-plex-token", token}],
      params: [includeHttps: 1]
    )
    |> result()
    |> case do
      {:ok, resources} when is_list(resources) -> {:ok, server_client_ids(resources)}
      {:ok, _other} -> {:error, :unexpected_response}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def server_machine_id do
    config = Application.get_env(:cinder, Cinder.Library.MediaServer.Plex, [])

    # A nil/blank base_url makes Req raise rather than return {:error, _} — guard it
    # (mirrors Cinder.Library.MediaServer.Plex.health/0).
    case Keyword.get(config, :url) do
      url when url in [nil, ""] -> {:error, :not_configured}
      url -> fetch_identity(url)
    end
  end

  @impl true
  def watchlist(token) do
    req(@discover_base_url)
    |> Req.merge(
      method: :get,
      url: "/library/sections/watchlist/all",
      headers: [{"x-plex-token", token}],
      params: [
        includeGuids: 1,
        "X-Plex-Container-Start": 0,
        "X-Plex-Container-Size": @watchlist_page_size
      ]
    )
    |> HTTPPolicy.bounded_request(@max_response_bytes)
    |> watchlist_result()
    |> case do
      {:ok, %{"MediaContainer" => %{} = container}} -> {:ok, watchlist_entries(container)}
      {:ok, _other} -> {:error, :unexpected_response}
      {:error, reason} -> {:error, reason}
    end
  end

  # A rejected token is its own outcome, not just another failed status: the caller parks that
  # user's sync on it instead of retrying every tick.
  defp watchlist_result({:ok, %{status: status}}) when status in [401, 403],
    do: {:error, :unauthorized}

  defp watchlist_result(response), do: result(response)

  # An empty watchlist comes back as a MediaContainer with no Metadata key at all.
  defp watchlist_entries(%{"Metadata" => metadata}) when is_list(metadata),
    do: Enum.flat_map(metadata, &watchlist_entry/1)

  defp watchlist_entries(_container), do: []

  # Drop anything plex.tv can't map to a TMDB id: there is nothing Cinder could request from it.
  defp watchlist_entry(%{"type" => type} = item) when is_binary(type) do
    case tmdb_id(item) do
      nil -> []
      id -> [%{tmdb_id: id, type: type, title: item["title"], year: item["year"]}]
    end
  end

  defp watchlist_entry(_item), do: []

  defp tmdb_id(%{"Guid" => guids}) when is_list(guids) do
    Enum.find_value(guids, fn
      %{"id" => "tmdb://" <> id} -> positive_integer(id)
      _ -> nil
    end)
  end

  defp tmdb_id(_item), do: nil

  defp positive_integer(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
  end

  defp server_client_ids(resources) do
    for %{"provides" => provides, "clientIdentifier" => id} <- resources,
        is_binary(provides) and String.contains?(provides, "server"),
        do: id
  end

  defp fetch_identity(url) do
    config = Application.get_env(:cinder, __MODULE__, [])

    [
      base_url: url,
      receive_timeout: 5_000,
      connect_options: [timeout: 5_000],
      retry: false,
      headers: [{"accept", "application/json"}]
    ]
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Keyword.put(:redirect, false)
    |> Req.new()
    |> Req.merge(method: :get, url: "/identity")
    |> HTTPPolicy.bounded_request(@max_response_bytes)
    |> result()
    |> case do
      {:ok, %{"MediaContainer" => %{"machineIdentifier" => id}}} -> {:ok, id}
      {:ok, _other} -> {:error, :unexpected_response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp req(base_url \\ @base_url) do
    config = Application.get_env(:cinder, __MODULE__, [])

    [
      base_url: base_url,
      receive_timeout: 15_000,
      pool_timeout: 5_000,
      connect_options: [timeout: 5_000],
      retry: false,
      headers: [
        {"x-plex-product", "Cinder"},
        {"x-plex-client-identifier", PlexAuth.client_identifier()},
        {"accept", "application/json"}
      ]
    ]
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Keyword.put(:redirect, false)
    |> Req.new()
  end

  defp request(method, url, options \\ []) do
    req()
    |> Req.merge([method: method, url: url] ++ options)
    |> HTTPPolicy.bounded_request(@max_response_bytes)
  end

  defp result({:ok, %{status: status, body: body}}) when status in 200..299, do: {:ok, body}
  defp result({:ok, %{status: status}}), do: {:error, {:plex_tv_status, status}}
  defp result({:error, reason}), do: {:error, reason}
end
