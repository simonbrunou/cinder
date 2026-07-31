defmodule Cinder.Library.MediaServer.Jellyfin do
  @moduledoc """
  Real `Cinder.Library.MediaServer` impl, backed by `Req`, against Jellyfin's
  HTTP API. `scan/1` triggers a full library refresh (`POST /Library/Refresh`),
  which covers every library — so the `kind` argument is ignored (Jellyfin has no
  per-library refresh endpoint and needs none). `list_users/0` reads `GET /Users`.

  Reads `url`, `api_key`, and optional `req_options` from
  `config :cinder, #{inspect(__MODULE__)}` at runtime. Validated against a live
  Jellyfin only in Phase 5.
  """
  @behaviour Cinder.Library.MediaServer

  alias Cinder.HTTPPolicy

  @max_response_bytes 4 * 1024 * 1024

  @impl true
  def scan(_kind), do: config() |> request(:post, "/Library/Refresh") |> result()

  @impl true
  # A nil/blank base_url makes Req raise (CaseClauseError in put_base_url) rather than
  # return {:error,_}, which `Cinder.Health` would rescue into an opaque "Check failed".
  # Guard it so an unconfigured Jellyfin shows a clean "Not configured" on /status.
  def health do
    config = config()

    case Keyword.get(config, :url) do
      url when url in [nil, ""] ->
        {:error, :not_configured}

      _ ->
        request(
          config,
          :get,
          "/System/Info",
          receive_timeout: 3_000,
          retry: false,
          connect_options: [timeout: 3_000]
        )
        |> result()
    end
  end

  @impl true
  # Jellyfin's user objects carry no email — only a name. A name that already IS an address
  # (the shape a Jellyseerr-style install ends up with) is taken as the account's email;
  # anything else comes back with `email: nil` and simply isn't importable.
  def list_users do
    config = config()

    case Keyword.get(config, :url) do
      url when url in [nil, ""] -> {:error, :not_configured}
      _ -> config |> request(:get, "/Users") |> users()
    end
  end

  defp users({:ok, %{status: status, body: body}}) when status in 200..299 and is_list(body) do
    {:ok,
     for %{"Id" => id, "Name" => name} <- body, is_binary(id) do
       %{id: id, email: email_from_name(name), username: presence(name)}
     end}
  end

  defp users({:ok, %{status: status}}) when status in 200..299, do: {:error, :unexpected_response}
  defp users({:ok, %{status: status}}), do: {:error, {:jellyfin_status, status}}
  defp users({:error, reason}), do: {:error, reason}

  # Deliberately the same shape `Cinder.Accounts.User` validates with, so a name that merely
  # contains an "@" ("Kim @ Home") isn't offered as an address the import would then reject.
  @email ~r/^[^@,;\s]+@[^@,;\s]+$/
  defp email_from_name(name) when is_binary(name) do
    if Regex.match?(@email, name), do: name
  end

  defp email_from_name(_), do: nil

  defp presence(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp presence(_), do: nil

  defp config, do: Application.get_env(:cinder, __MODULE__, [])

  defp req(config) do
    [
      base_url: Keyword.get(config, :url),
      receive_timeout: 15_000,
      pool_timeout: 5_000,
      connect_options: [timeout: 5_000],
      headers: [{"x-emby-token", Keyword.get(config, :api_key)}]
    ]
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Keyword.put(:redirect, false)
    |> Req.new()
  end

  defp request(config, method, url, options \\ []) do
    config
    |> req()
    |> Req.merge([method: method, url: url] ++ options)
    |> HTTPPolicy.bounded_request(@max_response_bytes)
  end

  defp result({:ok, %{status: status}}) when status in 200..299, do: :ok
  defp result({:ok, %{status: status}}), do: {:error, {:jellyfin_status, status}}
  defp result({:error, reason}), do: {:error, reason}
end
