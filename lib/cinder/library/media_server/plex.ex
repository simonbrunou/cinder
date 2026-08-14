defmodule Cinder.Library.MediaServer.Plex do
  @moduledoc """
  Real `Cinder.Library.MediaServer` impl, backed by `Req`, against Plex's HTTP
  API. `scan/1` refreshes one library section
  (`GET /library/sections/{section}/refresh`); `list_users/0` reads the shared-user list
  from plex.tv (`GET /api/v2/friends`) with the same token.

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
  @inventory_limit 5_000
  @identifier ~r/^[A-Za-z0-9_-]+$/
  @plex_tv_url "https://plex.tv"

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

  @impl true
  # The shared-user list comes from plex.tv, not the local server: the server's own
  # `/accounts` reports an id and a display name but NO email, and a Cinder account is keyed
  # by email. `/api/v2/friends` is the same list Plex's "Manage users" shows, read with the
  # configured server token (the owner's X-Plex-Token). Unvalidated against a live Plex.
  def list_users do
    config = Application.get_env(:cinder, __MODULE__, [])

    case Keyword.get(config, :token) do
      token when token in [nil, ""] ->
        {:error, :not_configured}

      _ ->
        config
        |> request(:get, "/api/v2/friends",
          base_url: @plex_tv_url,
          headers: [{"accept", "application/json"}]
        )
        |> users()
    end
  end

  @impl true
  def list_items(kind) do
    config = Application.get_env(:cinder, __MODULE__, [])

    with {:ok, section} <- section(config, kind),
         {:ok, machine_id} <- machine_id(config),
         {:ok, metadata} <- inventory(config, section) do
      {:ok, Enum.flat_map(metadata, &item(&1, machine_id, kind))}
    end
  end

  @impl true
  def deep_link("plex:" <> item_id) do
    with [machine_id, rating_key] when machine_id != "" and rating_key != "" <-
           String.split(item_id, ":", parts: 2),
         url when not is_nil(url) <- web_url() do
      key = URI.encode_www_form("/library/metadata/#{rating_key}")
      "#{plex_web_root(url)}#!/server/#{machine_id}/details?key=#{key}"
    else
      _ -> nil
    end
  end

  def deep_link(_item_id), do: nil

  # Entries without an integer id can't be linked back to a Plex account, so they're dropped
  # rather than imported as an unlinkable local account.
  defp users({:ok, %{status: status, body: body}}) when status in 200..299 and is_list(body) do
    {:ok,
     for %{"id" => id} = friend <- body, is_integer(id) do
       %{
         id: id,
         email: presence(friend["email"]),
         username: presence(friend["username"]) || presence(friend["title"])
       }
     end}
  end

  defp users({:ok, %{status: status}}) when status in 200..299, do: {:error, :unexpected_response}
  defp users({:ok, %{status: status}}), do: {:error, {:plex_status, status}}
  defp users({:error, reason}), do: {:error, reason}

  defp machine_id(config) do
    config
    |> request(:get, "/identity", headers: [{"accept", "application/json"}])
    |> case do
      {:ok, %{status: status, body: %{"MediaContainer" => %{"machineIdentifier" => id}}}}
      when status in 200..299 and is_binary(id) and id != "" ->
        if Regex.match?(@identifier, id), do: {:ok, id}, else: {:error, :unexpected_response}

      {:ok, %{status: status}} when status in 200..299 ->
        {:error, :unexpected_response}

      {:ok, %{status: status}} ->
        {:error, {:plex_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp inventory(config, section) do
    config
    |> request(:get, "/library/sections/#{section}/all",
      headers: [
        {"accept", "application/json"},
        {"x-plex-container-start", "0"},
        {"x-plex-container-size", Integer.to_string(@inventory_limit)}
      ],
      params: [{"includeGuids", "1"}]
    )
    |> inventory_result()
  end

  defp inventory_result({:ok, %{status: status, body: %{"MediaContainer" => container}}})
       when status in 200..299 and is_map(container) do
    metadata = Map.get(container, "Metadata", [])
    total = Map.get(container, "totalSize")

    cond do
      not is_list(metadata) -> {:error, :unexpected_response}
      is_integer(total) and total == length(metadata) -> {:ok, metadata}
      true -> {:error, :partial_inventory}
    end
  end

  defp inventory_result({:ok, %{status: status}}) when status in 200..299,
    do: {:error, :unexpected_response}

  defp inventory_result({:ok, %{status: status}}), do: {:error, {:plex_status, status}}
  defp inventory_result({:error, reason}), do: {:error, reason}

  defp item(%{"ratingKey" => rating_key, "type" => type, "Guid" => guids}, machine_id, kind)
       when is_binary(rating_key) and rating_key != "" and is_list(guids) do
    expected_type = if kind == :movies, do: "movie", else: "show"

    with true <- type == expected_type,
         true <- Regex.match?(@identifier, rating_key),
         tmdb_id when not is_nil(tmdb_id) <- tmdb_id(guids) do
      id = "plex:#{machine_id}:#{rating_key}"
      [%{id: id, tmdb_id: tmdb_id, deep_link: deep_link(id)}]
    else
      _ -> []
    end
  end

  defp item(_metadata, _machine_id, _kind), do: []

  defp tmdb_id(guids) do
    Enum.find_value(guids, fn
      %{"id" => "tmdb://" <> raw} -> positive_integer(raw)
      _ -> nil
    end)
  end

  defp positive_integer(raw) do
    case Integer.parse(raw) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
  end

  defp web_url do
    case Keyword.get(Application.get_env(:cinder, __MODULE__, []), :web_url) do
      "http://" <> rest = url when rest != "" -> String.trim_trailing(url, "/")
      "https://" <> rest = url when rest != "" -> String.trim_trailing(url, "/")
      _ -> nil
    end
  end

  defp plex_web_root(url) do
    cond do
      String.ends_with?(url, "/desktop") -> url <> "/"
      URI.parse(url).host == "app.plex.tv" -> url <> "/desktop/"
      String.ends_with?(url, "/web/index.html") -> url
      true -> url <> "/web/index.html"
    end
  end

  defp presence(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp presence(_), do: nil

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
