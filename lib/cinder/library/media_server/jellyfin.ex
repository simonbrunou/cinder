defmodule Cinder.Library.MediaServer.Jellyfin do
  @moduledoc """
  Real `Cinder.Library.MediaServer` impl, backed by `Req`, against Jellyfin's
  HTTP API. `scan/1` triggers a full library refresh (`POST /Library/Refresh`),
  which covers every library — so the `kind` argument is ignored (Jellyfin has no
  per-library refresh endpoint and needs none).

  Reads `url`, `api_key`, and optional `req_options` from
  `config :cinder, #{inspect(__MODULE__)}` at runtime. Validated against a live
  Jellyfin only in Phase 5.
  """
  @behaviour Cinder.Library.MediaServer

  @impl true
  def scan(_kind), do: config() |> req() |> Req.post(url: "/Library/Refresh") |> result()

  @impl true
  # A nil/blank base_url makes Req raise (CaseClauseError in put_base_url) rather than
  # return {:error,_}, which `Cinder.Health` would rescue into an opaque "Check failed".
  # Guard it so an unconfigured Jellyfin shows a clean "Not configured" on /status.
  def health do
    config = config()

    case Keyword.get(config, :url) do
      url when url in [nil, ""] -> {:error, :not_configured}
      _ -> config |> req() |> Req.get(url: "/System/Info", receive_timeout: 3_000) |> result()
    end
  end

  defp config, do: Application.get_env(:cinder, __MODULE__, [])

  defp req(config) do
    [
      base_url: Keyword.get(config, :url),
      headers: [{"x-emby-token", Keyword.get(config, :api_key)}]
    ]
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Req.new()
  end

  defp result({:ok, %{status: status}}) when status in 200..299, do: :ok
  defp result({:ok, %{status: status}}), do: {:error, {:jellyfin_status, status}}
  defp result({:error, reason}), do: {:error, reason}
end
