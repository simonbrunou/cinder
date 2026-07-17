defmodule Cinder.Accounts.PlexAuth.HTTP do
  @moduledoc """
  Real `Cinder.Accounts.PlexAuth` impl, backed by `Req`, against plex.tv's
  PIN-based OAuth API: create/check a PIN (`/api/v2/pins`), fetch the signed-in
  account (`/api/v2/user`), and list the servers it can reach (`/api/v2/resources`).
  `server_machine_id/0` instead hits the configured local Plex server's
  unauthenticated `/identity`.

  Reads `req_options` from `config :cinder, #{inspect(__MODULE__)}`; the local
  server's `url` comes from `config :cinder, Cinder.Library.MediaServer.Plex` (the
  same key the media-server impl reads). Validated against live plex.tv only at dogfood.
  """
  @behaviour Cinder.Accounts.PlexAuth

  alias Cinder.Accounts.PlexAuth
  alias Cinder.HTTPPolicy

  @max_response_bytes 4 * 1024 * 1024
  @base_url "https://plex.tv"

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

  defp req do
    config = Application.get_env(:cinder, __MODULE__, [])

    [
      base_url: @base_url,
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
