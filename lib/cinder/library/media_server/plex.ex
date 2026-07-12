defmodule Cinder.Library.MediaServer.Plex do
  @moduledoc """
  Real `Cinder.Library.MediaServer` impl, backed by `Req`, against Plex's HTTP
  API. `scan/1` refreshes one library section
  (`GET /library/sections/{section}/refresh`).

  Reads `url`, `token`, optional `req_options`, and a **per-kind** section id
  (`:movies_section`, `:tv_section`, …) from
  `config :cinder, #{inspect(__MODULE__)}` at runtime. Plex has no refresh-all
  endpoint, so each `Cinder.Library` kind carries its own numeric section id (the
  number in the Plex web URL for that library). Validated against a live Plex only
  in Phase 5.
  """
  @behaviour Cinder.Library.MediaServer

  alias Cinder.HTTPPolicy

  @max_response_bytes 4 * 1024 * 1024

  @impl true
  # ponytail: refreshes one section; loop `/library/sections` if you ever need all.
  def scan(kind) do
    config = Application.get_env(:cinder, __MODULE__, [])

    with {:ok, section} <- section(config, kind) do
      request(config, :get, "/library/sections/#{section}/refresh")
      |> result()
    end
  end

  @impl true
  # Probe EVERY kind's section so a misconfigured TV section is red on /status, not
  # just the movie one. GET /library/sections/<section> is both token-checked (401s on
  # a bad/expired token) AND section-checked (404s on a missing section id), so a
  # misconfigured token *or* section surfaces as unhealthy — unlike the unauthenticated
  # /identity, which 200s regardless. Folds per-kind results into one :ok | {:error,_}
  # (first failure wins) so `Cinder.Health.run/1` gets the shape it expects.
  def health do
    config = Application.get_env(:cinder, __MODULE__, [])

    # A nil/blank base_url makes Req raise rather than return {:error,_}, which
    # Cinder.Health would rescue into an opaque "Check failed". Guard it so an
    # unconfigured Plex shows a clean "Not configured" (mirrors Jellyfin).
    case Keyword.get(config, :url) do
      url when url in [nil, ""] -> {:error, :not_configured}
      _ -> check_all_sections(config)
    end
  end

  defp check_all_sections(config) do
    Enum.reduce_while(Cinder.Library.kinds(), :ok, fn kind, :ok ->
      case check_section(config, kind) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp check_section(config, kind) do
    with {:ok, section} <- section(config, kind) do
      request(
        config,
        :get,
        "/library/sections/#{section}",
        receive_timeout: 3_000,
        retry: false,
        connect_options: [timeout: 3_000]
      )
      |> result()
    end
  end

  # A nil/blank section builds `/library/sections//…`, which Plex 404s — and because
  # scan is best-effort that failure would be silent. Fail loudly (tagged with the kind)
  # so the misconfig is visible (red on /status) instead of a no-op scan that never refreshes.
  defp section(config, kind) do
    case Keyword.get(config, :"#{kind}_section") do
      nil ->
        {:error, {:plex_section_unset, kind}}

      s when is_binary(s) ->
        if String.trim(s) == "", do: {:error, {:plex_section_unset, kind}}, else: {:ok, s}

      s ->
        {:ok, s}
    end
  end

  defp req(config) do
    [
      base_url: Keyword.get(config, :url),
      receive_timeout: 15_000,
      pool_timeout: 5_000,
      connect_options: [timeout: 5_000],
      headers: [{"x-plex-token", Keyword.get(config, :token)}]
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
  defp result({:ok, %{status: status}}), do: {:error, {:plex_status, status}}
  defp result({:error, reason}), do: {:error, reason}
end
