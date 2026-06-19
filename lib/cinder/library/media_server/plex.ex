defmodule Cinder.Library.MediaServer.Plex do
  @moduledoc """
  Real `Cinder.Library.MediaServer` impl, backed by `Req`, against Plex's HTTP
  API. `scan/0` refreshes one library section
  (`GET /library/sections/{section}/refresh`).

  Reads `url`, `token`, `section`, and optional `req_options` from
  `config :cinder, #{inspect(__MODULE__)}` at runtime. Plex has no refresh-all
  endpoint, so `section` is the numeric id of the movie library (the number in
  the Plex web URL). Validated against a live Plex only in Phase 5.
  """
  @behaviour Cinder.Library.MediaServer

  @impl true
  # ponytail: refreshes one section; loop `/library/sections` if you ever need all.
  def scan do
    config = Application.get_env(:cinder, __MODULE__, [])

    [
      base_url: Keyword.get(config, :url),
      headers: [{"x-plex-token", Keyword.get(config, :token)}]
    ]
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Req.new()
    |> Req.get(url: "/library/sections/#{Keyword.get(config, :section)}/refresh")
    |> case do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} -> {:error, {:plex_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
