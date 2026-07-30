defmodule Cinder.Library.MigrationSource.Sonarr do
  @moduledoc """
  Sonarr v3 migration snapshot client.

  Reads `base_url`, `api_key`, optional path prefixes, and `req_options` from
  `config :cinder, #{inspect(__MODULE__)}` at runtime.
  """
  @behaviour Cinder.Library.MigrationSource

  alias Cinder.Download.PathMapping
  alias Cinder.HTTPPolicy
  alias Cinder.Util

  @max_response_bytes 8 * 1024 * 1024
  @series_concurrency 4
  @series_timeout 35_000

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
         files: normalized.files,
         diagnostics: normalized.diagnostics
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
    indexed = Enum.with_index(series, 1)
    owner = self()

    results =
      Task.async_stream(
        indexed,
        fn {raw, _index} ->
          with :ok <- allow_req_test(config, owner) do
            normalize_one_series(raw, config)
          end
        end,
        max_concurrency: @series_concurrency,
        timeout: @series_timeout,
        on_timeout: :kill_task,
        ordered: true
      )

    normalized =
      indexed
      |> Enum.zip(results)
      |> Enum.reduce(%{series: [], episodes: [], files: [], diagnostics: []}, &collect_series/2)

    {:ok,
     %{
       series: Enum.reverse(normalized.series),
       episodes: Enum.reverse(normalized.episodes),
       files: normalized.files |> Enum.reverse() |> Enum.uniq_by(& &1.provider_id),
       diagnostics: Enum.reverse(normalized.diagnostics)
     }}
  end

  defp allow_req_test(config, owner) do
    case get_in(config, [:req_options, :plug]) do
      {Req.Test, name} ->
        case Req.Test.allow(name, owner, self()) do
          :ok -> :ok
          {:error, %{reason: :cant_allow_in_shared_mode}} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _plug ->
        :ok
    end
  end

  defp collect_series({_source, {:ok, {:ok, item}}}, acc) do
    %{
      acc
      | series: [item.series | acc.series],
        episodes: Enum.reverse(item.episodes, acc.episodes),
        files: Enum.reverse(item.files, acc.files)
    }
  end

  defp collect_series({{raw, index}, {:ok, {:error, reason}}}, acc),
    do: add_diagnostic(acc, raw, index, reason)

  defp collect_series({{raw, index}, {:exit, reason}}, acc),
    do: add_diagnostic(acc, raw, index, reason)

  defp add_diagnostic(acc, raw, index, reason) do
    diagnostic = %{
      kind: :series,
      provider_id: Util.positive_integer(raw["id"]),
      title: series_name(raw, index),
      reason: {:series_snapshot_failed, diagnostic_reason(reason)}
    }

    %{acc | diagnostics: [diagnostic | acc.diagnostics]}
  end

  defp series_name(raw, index) do
    Util.trim_to_nil(raw["title"]) || Util.trim_to_nil(raw["sortTitle"]) ||
      case Util.positive_integer(raw["id"]) do
        nil -> "Series #{index}"
        id -> "Series #{id}"
      end
  end

  defp diagnostic_reason(%Req.TransportError{reason: reason}), do: reason
  defp diagnostic_reason(reason), do: reason

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
         series: %{provider_id: provider_id, tvdb_id: Util.positive_integer(raw["tvdbId"])},
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
          tvdb_id: Util.positive_integer(raw["tvdbId"]),
          season_number: season_number,
          episode_number: episode_number,
          file_id: Util.positive_integer(raw["episodeFileId"])
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
      id = Util.positive_integer(file["id"])
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
    Util.trim_to_nil(file["path"]) ||
      join_path(Util.trim_to_nil(series["path"]), Util.trim_to_nil(file["relativePath"]))
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

    if Util.trim_to_nil(config[:base_url]) && Util.trim_to_nil(config[:api_key]),
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
end
