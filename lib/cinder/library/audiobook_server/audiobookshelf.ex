defmodule Cinder.Library.AudiobookServer.Audiobookshelf do
  @moduledoc """
  Real `Cinder.Library.AudiobookServer` impl, backed by `Req`, against Audiobookshelf's own
  published HTTP API (`https://api.audiobookshelf.org/`). `scan/0` triggers
  `POST /api/libraries/:id/scan` for the configured library id. `health/0` is a cheap
  `GET /api/libraries` reachability probe, mirroring
  `Cinder.Library.MediaServer.Jellyfin.health/0`'s "guard the unconfigured case so `/status`
  shows a clean 'Not configured'" pattern.

  **No B0 fixture exists for this adapter.** Unlike Bookshelf's captured `/api/v1`
  (`test/support/fixtures/books/bookshelf-api-v1.json`), the B0 audit captured zero Audiobookshelf
  request/response evidence — see `docs/plans/2026-09-02-books-b7-audiobooks.md` §0.2. This module
  is built against Audiobookshelf's own documented, versioned API shape, never an invented one;
  its test stubs that documented shape directly via `Req.Test`, with no committed fixture to
  verify against.

  Reads `url`, `api_key`, `library_id`, and optional `req_options` from
  `config :cinder, #{inspect(__MODULE__)}` at runtime.
  """
  @behaviour Cinder.Library.AudiobookServer

  alias Cinder.HTTPPolicy

  @max_response_bytes 4 * 1024 * 1024

  @impl true
  def scan do
    config = config()

    case {presence(Keyword.get(config, :url)), presence(Keyword.get(config, :library_id))} do
      {nil, _library_id} ->
        {:error, :not_configured}

      {_url, nil} ->
        {:error, :not_configured}

      {_url, library_id} ->
        config |> request(:post, "/api/libraries/#{library_id}/scan") |> result()
    end
  end

  @impl true
  # A nil/blank base_url makes Req raise (CaseClauseError in put_base_url) rather than
  # return {:error, _}, which `Cinder.Health` would rescue into an opaque "Check failed".
  # Guard it so an unconfigured Audiobookshelf shows a clean "Not configured" on /status.
  def health do
    config = config()

    case presence(Keyword.get(config, :url)) do
      nil ->
        {:error, :not_configured}

      _url ->
        request(
          config,
          :get,
          "/api/libraries",
          receive_timeout: 3_000,
          retry: false,
          connect_options: [timeout: 3_000]
        )
        |> result()
    end
  end

  defp presence(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp presence(_value), do: nil

  defp config, do: Application.get_env(:cinder, __MODULE__, [])

  defp req(config) do
    [
      base_url: Keyword.get(config, :url),
      receive_timeout: 15_000,
      pool_timeout: 5_000,
      connect_options: [timeout: 5_000],
      headers: auth_header(Keyword.get(config, :api_key))
    ]
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Keyword.put(:redirect, false)
    |> Req.new()
  end

  defp auth_header(key) when is_binary(key) and key != "",
    do: [{"authorization", "Bearer #{key}"}]

  defp auth_header(_key), do: []

  defp request(config, method, url, options \\ []) do
    config
    |> req()
    |> Req.merge([method: method, url: url] ++ options)
    |> HTTPPolicy.bounded_request(@max_response_bytes)
  end

  defp result({:ok, %{status: status}}) when status in 200..299, do: :ok
  defp result({:ok, %{status: status}}), do: {:error, {:audiobookshelf_status, status}}
  defp result({:error, reason}), do: {:error, reason}
end
