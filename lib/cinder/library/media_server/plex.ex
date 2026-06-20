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

    with {:ok, section} <- section(config) do
      req(config)
      |> Req.get(url: "/library/sections/#{section}/refresh")
      |> result()
    end
  end

  @impl true
  # GET /library/sections/<section> is both token-checked (401s on a bad/expired
  # token) AND section-checked (404s on a missing section id), so a misconfigured
  # token *or* section surfaces as unhealthy on /status — unlike the unauthenticated
  # /identity, which 200s regardless and would hide the most common misconfig.
  def health do
    config = Application.get_env(:cinder, __MODULE__, [])

    with {:ok, section} <- section(config) do
      req(config)
      |> Req.get(url: "/library/sections/#{section}", receive_timeout: 3_000)
      |> result()
    end
  end

  # A nil/blank section builds `/library/sections//…`, which Plex 404s — and because
  # scan is best-effort that failure would be silent. Fail loudly so the misconfig is
  # visible (red on /status) instead of a no-op scan that never refreshes.
  defp section(config) do
    case Keyword.get(config, :section) do
      s when s in [nil, ""] -> {:error, :plex_section_unset}
      s -> {:ok, s}
    end
  end

  defp req(config) do
    [
      base_url: Keyword.get(config, :url),
      headers: [{"x-plex-token", Keyword.get(config, :token)}]
    ]
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Req.new()
  end

  defp result({:ok, %{status: status}}) when status in 200..299, do: :ok
  defp result({:ok, %{status: status}}), do: {:error, {:plex_status, status}}
  defp result({:error, reason}), do: {:error, reason}
end
