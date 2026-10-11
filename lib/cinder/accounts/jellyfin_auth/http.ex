defmodule Cinder.Accounts.JellyfinAuth.HTTP do
  @moduledoc """
  Real `Cinder.Accounts.JellyfinAuth` impl, backed by `Req`: one
  `POST /Users/AuthenticateByName` against the configured Jellyfin server. Rejected credentials
  come back as 400/401 and surface as `{:error, :invalid_credentials}` — every other failure
  keeps its own reason, but the controller shows one generic message either way.

  The server URL comes from `config :cinder, Cinder.Library.MediaServer.Jellyfin` (the same key
  the media-server impl reads); `req_options` from `config :cinder, #{inspect(__MODULE__)}`.
  Validated against a live Jellyfin only at dogfood.

  Emby exposes the same endpoint, the same `Pw` body and the same `x-emby-authorization`
  header, so pointing the URL at an Emby server may work — untested, not built for. The
  post-authentication checks below assume Jellyfin's `UserDto` contract (`Policy.IsDisabled`,
  `Policy.EnableRemoteAccess`); an Emby server that answers differently is refused (a missing
  `EnableRemoteAccess` counts as remote access off), not let through.
  """
  @behaviour Cinder.Accounts.JellyfinAuth

  alias Cinder.Accounts.JellyfinAuth
  alias Cinder.HTTPPolicy

  @max_response_bytes 1024 * 1024
  @path "/Users/AuthenticateByName"

  @impl true
  def authenticate(username, password) do
    # A nil/blank base_url makes Req raise rather than return {:error, _} — guard it
    # (mirrors Cinder.Library.MediaServer.Jellyfin.health/0).
    case Keyword.get(server_config(), :url) do
      url when url in [nil, ""] -> {:error, :not_configured}
      url -> post_credentials(url, username, password)
    end
  end

  defp post_credentials(url, username, password) do
    url
    |> request(json: %{"Username" => username, "Pw" => password})
    |> result()
    |> case do
      {:ok, %{"User" => %{"Id" => id} = user}} when is_binary(id) and id != "" ->
        account(id, user)

      {:ok, _other} ->
        {:error, :unexpected_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Cinder asks Jellyfin to check the credentials from its own LAN address, so Jellyfin's
  # per-user rules would otherwise apply to Cinder instead of to the visitor. Jellyfin signs a
  # passwordless user in on an empty `Pw` — the controller refuses an empty password before this
  # call, and that refusal is the guarantee (a passwordless user only authenticates with an empty
  # `Pw`). `HasPassword` is marked obsolete and always `true` on current Jellyfin, so it is
  # honoured only when a server explicitly reports `false`; a missing value never refuses.
  # A disabled user is refused on an explicit `IsDisabled: true`. The remote-access flag is handed
  # to the controller to compare with the browser's own address, and fails closed: anything but
  # an explicit `true` (including a missing policy) counts as remote access off.
  defp account(id, user) do
    policy = if is_map(user["Policy"]), do: user["Policy"], else: %{}

    cond do
      user["HasPassword"] == false ->
        {:error, :passwordless}

      policy["IsDisabled"] == true ->
        {:error, :disabled}

      true ->
        {:ok, %{id: id, name: user["Name"], remote_access: policy["EnableRemoteAccess"] == true}}
    end
  end

  defp request(url, options) do
    [
      base_url: url,
      receive_timeout: 15_000,
      pool_timeout: 5_000,
      connect_options: [timeout: 5_000],
      retry: false,
      headers: [
        {"x-emby-authorization", authorization()},
        {"accept", "application/json"}
      ]
    ]
    |> Keyword.merge(req_options())
    |> Keyword.put(:redirect, false)
    |> Req.new()
    |> Req.merge([method: :post, url: @path] ++ options)
    |> HTTPPolicy.bounded_request(@max_response_bytes)
  end

  # Jellyfin/Emby refuse AuthenticateByName without this header; DeviceId identifies the
  # per-install device session the server opens.
  defp authorization do
    ~s(MediaBrowser Client="Cinder", Device="Cinder", ) <>
      ~s(DeviceId="#{JellyfinAuth.device_id()}", Version="#{version()}")
  end

  defp version, do: to_string(Application.spec(:cinder, :vsn) || "0.0.0")

  defp server_config, do: Application.get_env(:cinder, Cinder.Library.MediaServer.Jellyfin, [])

  defp req_options,
    do: :cinder |> Application.get_env(__MODULE__, []) |> Keyword.get(:req_options, [])

  defp result({:ok, %{status: status, body: body}}) when status in 200..299, do: {:ok, body}

  defp result({:ok, %{status: status}}) when status in [400, 401, 403],
    do: {:error, :invalid_credentials}

  defp result({:ok, %{status: status}}), do: {:error, {:jellyfin_status, status}}
  defp result({:error, reason}), do: {:error, reason}
end
