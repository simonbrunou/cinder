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
  @inventory_limit 5_000
  # Episodes per page of the season read: a few hundred bytes each without images or user data.
  @episode_page 2_000

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

  @impl true
  def list_items(kind) do
    item_type = if kind == :movies, do: "Movie", else: "Series"
    config = config()

    case Keyword.get(config, :url) do
      url when url in [nil, ""] ->
        {:error, :not_configured}

      _ ->
        with {:ok, items} <- inventory(config, item_type, "ProviderIds") do
          {:ok, Enum.flat_map(items, &item/1)}
        end
    end
  end

  @impl true
  # A Season's `ChildCount` is only filled in for a user-bound request, and Cinder authenticates
  # with an API key (no user), so the counts come from the episodes themselves, joined to the
  # series inventory by `SeriesId`. `ExcludeLocationTypes=Virtual` drops the placeholder episodes
  # Jellyfin invents when "display missing episodes" is on. Unvalidated against a live Jellyfin.
  def list_seasons do
    config = config()

    case Keyword.get(config, :url) do
      url when url in [nil, ""] ->
        {:error, :not_configured}

      _ ->
        with {:ok, series} <- inventory(config, "Series", "ProviderIds"),
             {:ok, episodes} <- episodes(config, 0, []) do
          {:ok, count_seasons(series, episodes)}
        end
    end
  end

  # Paged: a household library can hold more episodes than one bounded response should carry.
  # A page that leaves the running total short of `TotalRecordCount` is a partial inventory.
  defp episodes(config, start, acc) do
    params = [
      {"Recursive", "true"},
      {"IncludeItemTypes", "Episode"},
      {"ExcludeLocationTypes", "Virtual"},
      {"EnableImages", "false"},
      {"EnableUserData", "false"},
      {"EnableTotalRecordCount", "true"},
      {"StartIndex", Integer.to_string(start)},
      {"Limit", Integer.to_string(@episode_page)}
    ]

    with {:ok, items, total} <- config |> request(:get, "/Items", params: params) |> page() do
      fetched = start + length(items)

      cond do
        fetched == total -> {:ok, items ++ acc}
        items != [] and fetched < total -> episodes(config, fetched, items ++ acc)
        true -> {:error, :partial_inventory}
      end
    end
  end

  defp count_seasons(series, episodes) do
    shows = for show <- series, %{} = item <- item(show), into: %{}, do: {show["Id"], item}

    counts =
      Enum.reduce(episodes, %{}, fn
        %{"SeriesId" => series_id, "ParentIndexNumber" => number} = episode, acc
        when is_integer(number) and number > 0 ->
          Map.update(acc, {series_id, number}, span(episode), &(&1 + span(episode)))

        _episode, acc ->
          acc
      end)

    for {{series_id, number}, count} <- counts, {:ok, show} <- [Map.fetch(shows, series_id)] do
      %{item_id: show.id, tmdb_id: show.tmdb_id, season_number: number, episode_count: count}
    end
  end

  # One file holding E01-E02 is a single episode item with an `IndexNumberEnd`.
  defp span(%{"IndexNumber" => first, "IndexNumberEnd" => last})
       when is_integer(first) and is_integer(last) and last >= first,
       do: last - first + 1

  defp span(_episode), do: 1

  @impl true
  def deep_link("jellyfin:" <> id) when id != "" do
    case web_url() do
      nil -> nil
      url -> "#{jellyfin_web_root(url)}/#/details?id=#{URI.encode_www_form(id)}"
    end
  end

  def deep_link(_item_id), do: nil

  defp users({:ok, %{status: status, body: body}}) when status in 200..299 and is_list(body) do
    {:ok,
     for %{"Id" => id, "Name" => name} <- body, is_binary(id) do
       %{id: id, email: email_from_name(name), username: presence(name)}
     end}
  end

  defp users({:ok, %{status: status}}) when status in 200..299, do: {:error, :unexpected_response}
  defp users({:ok, %{status: status}}), do: {:error, {:jellyfin_status, status}}
  defp users({:error, reason}), do: {:error, reason}

  defp inventory(config, item_type, fields) do
    config
    |> request(:get, "/Items",
      params: [
        {"Recursive", "true"},
        {"IncludeItemTypes", item_type},
        {"Fields", fields},
        {"EnableTotalRecordCount", "true"},
        {"Limit", Integer.to_string(@inventory_limit)}
      ]
    )
    |> inventory()
  end

  defp inventory({:ok, %{status: status, body: %{"Items" => items, "TotalRecordCount" => total}}})
       when status in 200..299 and is_list(items) and is_integer(total) and
              total == length(items),
       do: {:ok, items}

  defp inventory({:ok, %{status: status, body: %{"Items" => items}}})
       when status in 200..299 and is_list(items),
       do: {:error, :partial_inventory}

  defp inventory({:ok, %{status: status}}) when status in 200..299,
    do: {:error, :unexpected_response}

  defp inventory({:ok, %{status: status}}), do: {:error, {:jellyfin_status, status}}
  defp inventory({:error, reason}), do: {:error, reason}

  defp page({:ok, %{status: status, body: %{"Items" => items, "TotalRecordCount" => total}}})
       when status in 200..299 and is_list(items) and is_integer(total),
       do: {:ok, items, total}

  defp page(response), do: inventory(response)

  defp item(%{"Id" => id, "ProviderIds" => %{"Tmdb" => raw}})
       when is_binary(id) and id != "" and is_binary(raw) do
    case Integer.parse(raw) do
      {tmdb_id, ""} when tmdb_id > 0 ->
        item_id = "jellyfin:#{id}"
        [%{id: item_id, tmdb_id: tmdb_id, deep_link: deep_link(item_id)}]

      _ ->
        []
    end
  end

  defp item(_item), do: []

  defp web_url do
    case Keyword.get(config(), :web_url) do
      "http://" <> rest = url when rest != "" -> String.trim_trailing(url, "/")
      "https://" <> rest = url when rest != "" -> String.trim_trailing(url, "/")
      _ -> nil
    end
  end

  defp jellyfin_web_root(url) do
    if String.ends_with?(url, "/web"), do: url, else: url <> "/web"
  end

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
