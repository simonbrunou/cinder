defmodule Cinder.Library.MigrationSource.Sonarr do
  @moduledoc """
  Sonarr v3 migration snapshot client.

  Reads `base_url`, `api_key`, optional path prefixes, and `req_options` from
  `config :cinder, #{inspect(__MODULE__)}` at runtime.
  """
  @behaviour Cinder.Library.MigrationSource

  alias Cinder.Download.PathMapping
  alias Cinder.HTTPPolicy

  @max_response_bytes 8 * 1024 * 1024

  @impl true
  def snapshot do
    with {:ok, config} <- configured(),
         :ok <- mapping_health(config),
         {:ok, %{status: 200, body: series}} when is_list(series) <-
           request(config, url: "/api/v3/series"),
         {:ok, normalized} <- normalize_series(series, config) do
      {:ok,
       %{
         movies: [],
         series: normalized.series,
         episodes: normalized.episodes,
         files: normalized.files
       }}
    else
      {:ok, %{status: 200}} -> {:error, :unexpected_response}
      {:ok, %{status: status}} -> {:error, {:sonarr_status, status}}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def health do
    with {:ok, config} <- configured(),
         {:ok, %{status: status}} when status in 200..299 <-
           request(config,
             url: "/api/v3/system/status",
             receive_timeout: 3_000,
             connect_options: [timeout: 3_000]
           ),
         :ok <- mapping_health(config) do
      :ok
    else
      {:ok, %{status: status}} -> {:error, {:sonarr_status, status}}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_series(series, config) do
    Enum.reduce_while(series, {:ok, %{series: [], episodes: [], files: []}}, fn raw, {:ok, acc} ->
      case normalize_one_series(raw, config) do
        {:ok, normalized} ->
          {:cont,
           {:ok,
            %{
              series: [normalized.series | acc.series],
              episodes: Enum.reverse(normalized.episodes, acc.episodes),
              files: Enum.reverse(normalized.files, acc.files)
            }}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} ->
        {:ok,
         %{
           series: Enum.reverse(normalized.series),
           episodes: Enum.reverse(normalized.episodes),
           files: normalized.files |> Enum.reverse() |> Enum.uniq_by(& &1.provider_id)
         }}

      error ->
        error
    end
  end

  defp normalize_one_series(%{"id" => provider_id} = raw, config)
       when is_integer(provider_id) and provider_id > 0 do
    with {:ok, %{status: 200, body: episodes}} when is_list(episodes) <-
           request(config,
             url: "/api/v3/episode",
             params: [seriesId: provider_id, includeEpisodeFile: true]
           ),
         {:ok, normalized_episodes} <- normalize_episodes(episodes, provider_id),
         {:ok, files} <- episode_files(episodes, normalized_episodes, raw, config) do
      {:ok,
       %{
         series: %{provider_id: provider_id, tvdb_id: positive_integer(raw["tvdbId"])},
         episodes: normalized_episodes,
         files: files
       }}
    else
      {:ok, %{status: 200}} -> {:error, :unexpected_response}
      {:ok, %{status: status}} -> {:error, {:sonarr_status, status}}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_one_series(_raw, _config), do: {:error, :unexpected_response}

  defp normalize_episodes(episodes, series_id) do
    Enum.reduce_while(episodes, {:ok, []}, fn
      %{
        "id" => provider_id,
        "seasonNumber" => season_number,
        "episodeNumber" => episode_number
      } = raw,
      {:ok, acc}
      when is_integer(provider_id) and provider_id > 0 and is_integer(season_number) and
             season_number >= 0 and is_integer(episode_number) and episode_number >= 0 ->
        episode = %{
          provider_id: provider_id,
          series_id: series_id,
          tvdb_id: positive_integer(raw["tvdbId"]),
          season_number: season_number,
          episode_number: episode_number,
          file_id: positive_integer(raw["episodeFileId"])
        }

        {:cont, {:ok, [episode | acc]}}

      _raw, _acc ->
        {:halt, {:error, :unexpected_response}}
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp episode_files(raw_episodes, episodes, series, config) do
    nested =
      raw_episodes
      |> Enum.flat_map(fn
        %{"episodeFile" => file} when is_map(file) -> [file]
        _ -> []
      end)
      |> normalize_files(series, config)

    missing? =
      episodes
      |> Enum.map(& &1.file_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.any?(&(not Map.has_key?(nested, &1)))

    if missing? do
      fetch_episode_files(series["id"], series, config)
    else
      {:ok, Map.values(nested)}
    end
  end

  defp fetch_episode_files(series_id, series, config) do
    case request(config, url: "/api/v3/episodefile", params: [seriesId: series_id]) do
      {:ok, %{status: 200, body: files}} when is_list(files) ->
        {:ok, files |> normalize_files(series, config) |> Map.values()}

      {:ok, %{status: 200}} ->
        {:error, :unexpected_response}

      {:ok, %{status: status}} ->
        {:error, {:sonarr_status, status}}

      {:error, _reason} = error ->
        error
    end
  end

  defp normalize_files(files, series, config) do
    Map.new(files, fn file ->
      id = positive_integer(file["id"])
      {id, normalize_file(file, series, id, config)}
    end)
    |> Map.reject(fn {id, file} -> is_nil(id) or is_nil(file) end)
  end

  defp normalize_file(file, series, id, config) when is_integer(id) do
    with path when is_binary(path) <- file_path(file, series),
         size when is_integer(size) and size >= 0 <- file["size"] do
      %{
        provider_id: id,
        kind: :episode,
        path: translate(path, config),
        size: size
      }
    else
      _ -> nil
    end
  end

  defp normalize_file(_file, _series, _id, _config), do: nil

  defp file_path(file, series) do
    nonblank(file["path"]) ||
      join_path(nonblank(series["path"]), nonblank(file["relativePath"]))
  end

  defp join_path(root, relative) when is_binary(root) and is_binary(relative),
    do: Path.join(root, relative)

  defp join_path(_root, _relative), do: nil

  defp translate(path, config) do
    PathMapping.translate(path, config[:remote_path_prefix], config[:local_path_prefix])
  end

  defp mapping_health(config) do
    PathMapping.validate_local_prefix(
      config[:remote_path_prefix],
      config[:local_path_prefix]
    )
  end

  defp configured do
    config = Application.get_env(:cinder, __MODULE__, [])

    if nonblank(config[:base_url]) && nonblank(config[:api_key]),
      do: {:ok, config},
      else: {:error, :not_configured}
  end

  defp request(config, opts) do
    [
      base_url: config[:base_url],
      headers: [{"x-api-key", config[:api_key]}],
      receive_timeout: 15_000,
      pool_timeout: 5_000,
      connect_options: [timeout: 5_000],
      retry: false
    ]
    |> Keyword.merge(opts)
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Keyword.put(:redirect, false)
    |> Req.new()
    |> HTTPPolicy.bounded_request(@max_response_bytes)
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil

  defp nonblank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp nonblank(_value), do: nil
end
