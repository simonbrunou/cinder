defmodule Cinder.Library.MediaServer.Jellyfin do
  @moduledoc """
  Real `Cinder.Library.MediaServer` impl, backed by `Req`, against Jellyfin's
  HTTP API. `scan/0` triggers a full library refresh (`POST /Library/Refresh`).

  Reads `url`, `api_key`, and optional `req_options` from
  `config :cinder, #{inspect(__MODULE__)}` at runtime. Validated against a live
  Jellyfin only in Phase 5.
  """
  @behaviour Cinder.Library.MediaServer

  @impl true
  def scan do
    config = Application.get_env(:cinder, __MODULE__, [])

    [
      base_url: Keyword.get(config, :url),
      headers: [{"x-emby-token", Keyword.get(config, :api_key)}]
    ]
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Req.new()
    |> Req.post(url: "/Library/Refresh")
    |> case do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} -> {:error, {:jellyfin_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
