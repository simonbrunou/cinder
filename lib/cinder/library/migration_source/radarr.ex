defmodule Cinder.Library.MigrationSource.Radarr do
  @moduledoc """
  Radarr v3 migration snapshot client.

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
         {:ok, %{status: 200, body: movies}} when is_list(movies) <-
           request(config, url: "/api/v3/movie"),
         {:ok, normalized} <- normalize_movies(movies, config) do
      {:ok, %{movies: normalized.movies, series: [], episodes: [], files: normalized.files}}
    else
      {:ok, %{status: 200}} -> {:error, :unexpected_response}
      {:ok, %{status: status}} -> {:error, {:radarr_status, status}}
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
      {:ok, %{status: status}} -> {:error, {:radarr_status, status}}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_movies(movies, config) do
    Enum.reduce_while(movies, {:ok, %{movies: [], files: []}}, fn raw, {:ok, acc} ->
      case normalize_movie(raw, config) do
        {:ok, movie, nil} ->
          {:cont, {:ok, %{acc | movies: [movie | acc.movies]}}}

        {:ok, movie, file} ->
          {:cont, {:ok, %{movies: [movie | acc.movies], files: [file | acc.files]}}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} ->
        {:ok,
         %{
           movies: Enum.reverse(normalized.movies),
           files: normalized.files |> Enum.reverse() |> Enum.uniq_by(& &1.provider_id)
         }}

      error ->
        error
    end
  end

  defp normalize_movie(%{"id" => provider_id} = raw, config)
       when is_integer(provider_id) and provider_id > 0 do
    movie_file = Map.get(raw, "movieFile")
    file_id = positive_integer(raw["movieFileId"]) || nested_id(movie_file)

    movie = %{
      provider_id: provider_id,
      tmdb_id: positive_integer(raw["tmdbId"]),
      imdb_id: nonblank(raw["imdbId"]),
      file_id: file_id
    }

    {:ok, movie, normalize_file(movie_file, raw, file_id, config)}
  end

  defp normalize_movie(_raw, _config), do: {:error, :unexpected_response}

  defp normalize_file(file, movie, file_id, config)
       when is_map(file) and is_integer(file_id) do
    with path when is_binary(path) <- file_path(file, movie),
         size when is_integer(size) and size >= 0 <- file["size"] do
      %{
        provider_id: file_id,
        kind: :movie,
        path: translate(path, config),
        size: size
      }
    else
      _ -> nil
    end
  end

  defp normalize_file(_file, _movie, _file_id, _config), do: nil

  defp file_path(file, movie) do
    nonblank(file["path"]) ||
      join_path(nonblank(movie["path"]), nonblank(file["relativePath"]))
  end

  defp join_path(root, relative) when is_binary(root) and is_binary(relative),
    do: Path.join(root, relative)

  defp join_path(_root, _relative), do: nil

  defp nested_id(%{"id" => id}), do: positive_integer(id)
  defp nested_id(_file), do: nil

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
