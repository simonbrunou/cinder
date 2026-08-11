defmodule Cinder.Subtitles.Manifest do
  @moduledoc false

  require Logger

  alias Cinder.Library.PathPolicy
  alias Cinder.Settings

  @origins ~w(opensubtitles_hash opensubtitles_id embedded translated release_sidecar)
  @sync_statuses ~w(aligned review)
  @sync_methods ~w(embedded audio manual)
  @sidecar_extensions ~w(.srt .ass .ssa .sub .vtt)
  @sha256 ~r/\A[0-9a-f]{64}\z/

  @spec path(String.t()) :: String.t()
  def path(video_path) do
    Path.join(
      Path.dirname(video_path),
      "." <> Path.basename(video_path) <> ".cinder-subtitles.json"
    )
  end

  @spec read(String.t()) :: %{video_moviehash: String.t() | nil, tracks: map()}
  def read(video_path) do
    case safe_destination(path(video_path)) do
      {:ok, manifest_path} -> read_manifest(manifest_path, video_path)
      {:error, :unsafe_destination} -> empty()
    end
  end

  defp read_manifest(manifest_path, video_path) do
    case fs().read(manifest_path) do
      {:ok, json} -> decode(json, video_path)
      _ -> empty()
    end
  end

  @spec put(String.t(), String.t() | nil, String.t(), String.t() | atom(), String.t() | nil) ::
          :ok | {:error, term()}
  def put(video_path, moviehash, language, origin, sidecar_path \\ nil) do
    with {:ok, file} <- normalize_put_file(video_path, sidecar_path) do
      track = %{origin: to_string(origin)}
      track = if file, do: Map.put(track, :file, file), else: track

      state =
        video_path
        |> read()
        |> put_in([:tracks, language], track)
        |> Map.put(:video_moviehash, moviehash)

      write(video_path, state)
    end
  end

  @spec put_sync(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def put_sync(video_path, language, sync) do
    state = read(video_path)

    with {:ok, sync} <- normalize_sync(sync),
         %{origin: _origin} = track <- get_in(state, [:tracks, language]) do
      track = track |> Map.delete(:sync_invalid?) |> Map.put(:sync, sync)
      write(video_path, put_in(state, [:tracks, language], track))
    else
      nil -> {:error, :unknown_track}
      :error -> {:error, :invalid_sync}
    end
  end

  @spec clear_sync(String.t(), String.t()) :: :ok | {:error, term()}
  def clear_sync(video_path, language) do
    state = read(video_path)

    case get_in(state, [:tracks, language]) do
      %{origin: _origin} = track ->
        track = Map.drop(track, [:sync, :sync_invalid?])
        write(video_path, put_in(state, [:tracks, language], track))

      nil ->
        :ok
    end
  end

  @spec sync(map(), String.t()) :: map() | nil
  def sync(state, language), do: get_in(state, [:tracks, language, :sync])

  defp write(video_path, state) do
    manifest_path = path(video_path)

    temporary =
      Path.join(
        Path.dirname(manifest_path),
        ".cinder-subtitle-manifest-#{System.unique_integer([:positive])}"
      )

    with {:ok, manifest_path} <- safe_destination(manifest_path),
         {:ok, temporary} <- safe_destination(temporary),
         {:ok, json} <- Jason.encode(state),
         :ok <- fs().write(temporary, json) do
      rename_manifest(temporary, manifest_path)
    end
  end

  defp rename_manifest(temporary, manifest_path) do
    result =
      with {:ok, temporary} <- safe_destination(temporary),
           {:ok, manifest_path} <- safe_destination(manifest_path) do
        fs().rename(temporary, manifest_path)
      end

    if result != :ok, do: safe_remove(temporary)
    result
  end

  @spec stable?(map(), String.t() | nil, String.t()) :: boolean()
  def stable?(state, moviehash, language) when is_binary(moviehash) do
    state.video_moviehash == moviehash and verified?(state, language)
  end

  def stable?(_state, _moviehash, _language), do: false

  @spec provisional?(map(), String.t() | nil, String.t()) :: boolean()
  def provisional?(state, moviehash, language),
    do: managed?(state, language) and not stable?(state, moviehash, language)

  @spec managed?(map(), String.t()) :: boolean()
  def managed?(state, language), do: origin(state, language) in @origins

  # Hash-verified origin regardless of whether the stored moviehash still matches — callers that
  # can't compute a current hash use this to avoid downgrading a verified entry they can't check.
  @spec verified?(map(), String.t()) :: boolean()
  def verified?(state, language), do: origin(state, language) == "opensubtitles_hash"

  defp decode(json, video_path) do
    with {:ok, %{"video_moviehash" => moviehash, "tracks" => tracks}}
         when is_map(tracks) <- Jason.decode(json),
         true <- is_binary(moviehash) or is_nil(moviehash),
         {:ok, tracks} <- normalize_tracks(tracks) do
      %{video_moviehash: moviehash, tracks: tracks}
    else
      _ ->
        Logger.warning("subtitle manifest is malformed for #{video_path}")
        empty()
    end
  end

  defp normalize_tracks(tracks) do
    tracks
    |> Enum.reduce_while({:ok, %{}}, fn
      {language, %{"origin" => origin} = track}, {:ok, acc}
      when is_binary(language) and origin in @origins ->
        normalized =
          %{origin: origin}
          |> Map.merge(normalize_optional_file(track))
          |> Map.merge(normalize_optional_sync(track))

        {:cont, {:ok, Map.put(acc, language, normalized)}}

      _, _ ->
        {:halt, :error}
    end)
  end

  defp normalize_optional_sync(%{"sync_invalid?" => true}), do: %{sync_invalid?: true}

  defp normalize_optional_sync(%{"sync" => sync}) do
    case normalize_sync(sync) do
      {:ok, normalized} -> %{sync: normalized}
      :error -> %{sync_invalid?: true}
    end
  end

  defp normalize_optional_sync(_track), do: %{}

  defp normalize_optional_file(%{"file_invalid?" => true}), do: %{file_invalid?: true}

  defp normalize_optional_file(%{"file" => file}) do
    if valid_sidecar_basename?(file), do: %{file: file}, else: %{file_invalid?: true}
  end

  defp normalize_optional_file(_track), do: %{}

  defp normalize_put_file(_video_path, nil), do: {:ok, nil}

  defp normalize_put_file(video_path, sidecar_path) when is_binary(sidecar_path) do
    basename = Path.basename(sidecar_path)

    if Path.dirname(sidecar_path) == Path.dirname(video_path) and
         valid_sidecar_basename?(basename),
       do: {:ok, basename},
       else: {:error, :invalid_sidecar_file}
  end

  defp normalize_put_file(_video_path, _sidecar_path), do: {:error, :invalid_sidecar_file}

  defp valid_sidecar_basename?(file) do
    is_binary(file) and file != "" and Path.basename(file) == file and
      String.downcase(Path.extname(file)) in @sidecar_extensions
  end

  defp normalize_sync(sync) when is_map(sync) do
    normalized = %{
      status: value(sync, :status),
      method: value(sync, :method),
      moviehash: value(sync, :moviehash),
      source_sha256: value(sync, :source_sha256),
      applied_sha256: value(sync, :applied_sha256),
      offset_ms: value(sync, :offset_ms),
      rate: value(sync, :rate),
      score: value(sync, :score),
      reason: value(sync, :reason)
    }

    if valid_sync?(normalized),
      do: {:ok, %{normalized | rate: normalized.rate * 1.0}},
      else: :error
  end

  defp normalize_sync(_sync), do: :error

  defp valid_sync?(sync) do
    Enum.all?([
      sync.status in @sync_statuses,
      sync.method in @sync_methods,
      is_binary(sync.moviehash) or is_nil(sync.moviehash),
      valid_sha256?(sync.source_sha256),
      valid_sha256?(sync.applied_sha256),
      is_integer(sync.offset_ms),
      is_number(sync.rate) and sync.rate > 0,
      is_number(sync.score) or is_nil(sync.score),
      is_binary(sync.reason) or is_nil(sync.reason)
    ])
  end

  defp valid_sha256?(value), do: is_binary(value) and Regex.match?(@sha256, value)
  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp origin(state, language), do: get_in(state, [:tracks, language, :origin])
  defp empty, do: %{video_moviehash: nil, tracks: %{}}
  defp fs, do: Application.fetch_env!(:cinder, :filesystem)
  defp path_policy, do: Application.get_env(:cinder, :path_policy, PathPolicy)

  defp safe_destination(path),
    do: path_policy().destination(path, Settings.library_roots(), filesystem: fs())

  defp safe_remove(path) do
    with :ok <-
           path_policy().deletable_file(path, Settings.library_roots(), filesystem: fs()),
         do: fs().rm(path)
  end
end
