defmodule Cinder.Subtitles.Manifest do
  @moduledoc false

  require Logger

  alias Cinder.Library.PathPolicy
  alias Cinder.Settings

  @origins ~w(opensubtitles_hash opensubtitles_id embedded translated release_sidecar)
  @sync_statuses ~w(aligned review applying)
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

  @spec put(
          String.t(),
          String.t() | nil,
          String.t(),
          String.t() | atom(),
          String.t() | nil,
          String.t() | nil,
          map() | nil
        ) ::
          :ok | {:error, term()}
  def put(
        video_path,
        moviehash,
        language,
        origin,
        sidecar_path \\ nil,
        managed_sha256 \\ nil,
        replacement_cleanup_sync \\ nil
      ) do
    with {:ok, file} <- normalize_put_file(video_path, sidecar_path),
         {:ok, managed_sha256} <- normalize_put_sha256(managed_sha256),
         {:ok, replacement_cleanup_sync} <- normalize_put_sync(replacement_cleanup_sync) do
      track = %{origin: to_string(origin)}
      track = if file, do: Map.put(track, :file, file), else: track
      track = if managed_sha256, do: Map.put(track, :managed_sha256, managed_sha256), else: track

      track =
        if replacement_cleanup_sync,
          do: Map.put(track, :replacement_cleanup_sync, replacement_cleanup_sync),
          else: track

      state = read(video_path)

      track =
        case get_in(state, [:tracks, language, :backup_tombstone]) do
          nil -> track
          tombstone -> Map.put(track, :backup_tombstone, tombstone)
        end

      state =
        state
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

  @spec replacement_cleanup_sync(map(), String.t()) :: map() | nil
  def replacement_cleanup_sync(state, language),
    do: get_in(state, [:tracks, language, :replacement_cleanup_sync])

  @spec begin_replacement_cleanup(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def begin_replacement_cleanup(video_path, language, sync) do
    state = read(video_path)

    with {:ok, sync} <- normalize_sync(sync),
         %{origin: _origin} = track <- get_in(state, [:tracks, language]) do
      track =
        track
        |> Map.drop([:sync, :sync_invalid?])
        |> Map.put(:replacement_cleanup_sync, sync)

      write(video_path, put_in(state, [:tracks, language], track))
    else
      nil -> {:error, :unknown_track}
      :error -> {:error, :invalid_replacement_cleanup_sync}
    end
  end

  @spec clear_replacement_cleanup(String.t(), String.t()) :: :ok | {:error, term()}
  def clear_replacement_cleanup(video_path, language) do
    state = read(video_path)

    case get_in(state, [:tracks, language]) do
      %{origin: _origin} = track ->
        write(
          video_path,
          put_in(state, [:tracks, language], Map.delete(track, :replacement_cleanup_sync))
        )

      nil ->
        :ok
    end
  end

  @spec reset_cleanup_sync(map(), String.t()) :: map() | nil
  def reset_cleanup_sync(state, language),
    do: get_in(state, [:tracks, language, :reset_cleanup_sync])

  @spec begin_reset_cleanup(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def begin_reset_cleanup(video_path, language, sync) do
    state = read(video_path)

    with {:ok, sync} <- normalize_put_sync(sync),
         %{origin: _origin} = track <- get_in(state, [:tracks, language]) do
      write(
        video_path,
        put_in(state, [:tracks, language], Map.put(track, :reset_cleanup_sync, sync))
      )
    else
      nil -> {:error, :unknown_track}
      {:error, _reason} = error -> error
    end
  end

  @spec finish_reset_cleanup(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def finish_reset_cleanup(video_path, language, sync) do
    state = read(video_path)

    with {:ok, sync} <- normalize_sync(sync),
         %{origin: _origin} = track <- get_in(state, [:tracks, language]) do
      track =
        track
        |> Map.drop([:sync_invalid?, :reset_cleanup_sync])
        |> Map.put(:sync, sync)

      write(video_path, put_in(state, [:tracks, language], track))
    else
      nil -> {:error, :unknown_track}
      :error -> {:error, :invalid_sync}
    end
  end

  @spec finish_reset_cleanup(String.t(), String.t()) :: :ok | {:error, term()}
  def finish_reset_cleanup(video_path, language) do
    state = read(video_path)

    case get_in(state, [:tracks, language]) do
      %{origin: _origin} = track ->
        track = Map.drop(track, [:sync, :sync_invalid?, :reset_cleanup_sync])
        write(video_path, put_in(state, [:tracks, language], track))

      nil ->
        :ok
    end
  end

  @spec backup_tombstone(map(), String.t()) :: map() | nil
  def backup_tombstone(state, language),
    do: get_in(state, [:tracks, language, :backup_tombstone])

  @spec put_backup_tombstone(String.t(), String.t(), term()) :: :ok | {:error, term()}
  def put_backup_tombstone(video_path, language, identity) do
    state = read(video_path)

    with {:ok, tombstone} <- normalize_backup_tombstone(%{identity: identity}),
         %{origin: _origin} = track <- get_in(state, [:tracks, language]) do
      write(
        video_path,
        put_in(state, [:tracks, language], Map.put(track, :backup_tombstone, tombstone))
      )
    else
      nil -> {:error, :unknown_track}
      :error -> {:error, :invalid_backup_tombstone}
    end
  end

  @spec clear_backup_tombstone(String.t(), String.t()) :: :ok | {:error, term()}
  def clear_backup_tombstone(video_path, language) do
    state = read(video_path)

    case get_in(state, [:tracks, language]) do
      %{origin: _origin} = track ->
        write(
          video_path,
          put_in(state, [:tracks, language], Map.delete(track, :backup_tombstone))
        )

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
         :ok <- fs().write_exclusive(temporary, json) do
      rename_manifest(temporary, manifest_path, json)
    end
  end

  defp rename_manifest(temporary, manifest_path, expected) do
    result =
      with {:ok, temporary} <- safe_destination(temporary),
           {:ok, manifest_path} <- safe_destination(manifest_path) do
        fs().rename(temporary, manifest_path)
      end

    case result do
      :ok ->
        :ok

      {:error, {:effect_committed, "rename", _reason}} = error ->
        verified = fs().read(manifest_path) == {:ok, expected}
        _ = safe_remove(temporary)
        if verified, do: :ok, else: error

      error ->
        _ = safe_remove(temporary)
        error
    end
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
          |> Map.merge(normalize_optional_managed_sha256(track))
          |> Map.merge(normalize_optional_sync(track))
          |> Map.merge(normalize_optional_replacement_cleanup_sync(track))
          |> Map.merge(normalize_optional_reset_cleanup_sync(track))
          |> Map.merge(normalize_optional_backup_tombstone(track))

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

  defp normalize_optional_replacement_cleanup_sync(%{"replacement_cleanup_sync" => sync}) do
    case normalize_sync(sync) do
      {:ok, normalized} -> %{replacement_cleanup_sync: normalized}
      :error -> %{replacement_cleanup_sync_invalid?: true}
    end
  end

  defp normalize_optional_replacement_cleanup_sync(%{
         "replacement_cleanup_sync_invalid?" => true
       }),
       do: %{replacement_cleanup_sync_invalid?: true}

  defp normalize_optional_replacement_cleanup_sync(_track), do: %{}

  defp normalize_optional_reset_cleanup_sync(%{"reset_cleanup_sync" => sync}) do
    case normalize_sync(sync) do
      {:ok, normalized} -> %{reset_cleanup_sync: normalized}
      :error -> %{reset_cleanup_sync_invalid?: true}
    end
  end

  defp normalize_optional_reset_cleanup_sync(%{"reset_cleanup_sync_invalid?" => true}),
    do: %{reset_cleanup_sync_invalid?: true}

  defp normalize_optional_reset_cleanup_sync(_track), do: %{}

  defp normalize_optional_backup_tombstone(%{"backup_tombstone" => tombstone}) do
    case normalize_backup_tombstone(tombstone) do
      {:ok, normalized} -> %{backup_tombstone: normalized}
      :error -> %{backup_tombstone_invalid?: true}
    end
  end

  defp normalize_optional_backup_tombstone(%{"backup_tombstone_invalid?" => true}),
    do: %{backup_tombstone_invalid?: true}

  defp normalize_optional_backup_tombstone(_track), do: %{}

  defp normalize_backup_tombstone(tombstone) when is_map(tombstone) do
    tombstone |> value(:identity) |> normalize_backup_identity()
  end

  defp normalize_backup_tombstone(_tombstone), do: :error

  defp normalize_backup_identity({major, minor, inode}),
    do: normalize_backup_identity([major, minor, inode])

  defp normalize_backup_identity([major, minor, inode])
       when is_integer(major) and major >= 0 and is_integer(minor) and minor >= 0 and
              is_integer(inode) and inode > 0,
       do: {:ok, %{identity: [major, minor, inode]}}

  defp normalize_backup_identity(_identity), do: :error

  defp normalize_optional_file(%{"file_invalid?" => true}), do: %{file_invalid?: true}

  defp normalize_optional_file(%{"file" => file}) do
    if valid_sidecar_basename?(file), do: %{file: file}, else: %{file_invalid?: true}
  end

  defp normalize_optional_file(_track), do: %{}

  defp normalize_optional_managed_sha256(%{"managed_sha256" => value}) do
    if valid_sha256?(value), do: %{managed_sha256: value}, else: %{managed_sha256_invalid?: true}
  end

  defp normalize_optional_managed_sha256(_track), do: %{}

  defp normalize_put_file(_video_path, nil), do: {:ok, nil}

  defp normalize_put_file(video_path, sidecar_path) when is_binary(sidecar_path) do
    basename = Path.basename(sidecar_path)

    if Path.dirname(sidecar_path) == Path.dirname(video_path) and
         valid_sidecar_basename?(basename),
       do: {:ok, basename},
       else: {:error, :invalid_sidecar_file}
  end

  defp normalize_put_file(_video_path, _sidecar_path), do: {:error, :invalid_sidecar_file}

  defp normalize_put_sha256(nil), do: {:ok, nil}

  defp normalize_put_sha256(value) do
    if valid_sha256?(value), do: {:ok, value}, else: {:error, :invalid_managed_sha256}
  end

  defp normalize_put_sync(nil), do: {:ok, nil}

  defp normalize_put_sync(sync) do
    case normalize_sync(sync) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, :invalid_replacement_cleanup_sync}
    end
  end

  defp valid_sidecar_basename?(file) do
    is_binary(file) and file != "" and Path.basename(file) == file and
      String.downcase(Path.extname(file)) in @sidecar_extensions
  end

  defp normalize_sync(sync) when is_map(sync) do
    normalized =
      %{
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
      |> maybe_put_version(sync)
      |> maybe_put_expected_sha256(sync)
      |> maybe_put_operation_id(sync)

    if valid_sync?(normalized),
      do: {:ok, %{normalized | rate: normalized.rate * 1.0}},
      else: :error
  end

  defp normalize_sync(_sync), do: :error

  defp maybe_put_version(normalized, sync) do
    case value(sync, :version) do
      version when is_integer(version) and version > 0 ->
        Map.put(normalized, :version, version)

      _ ->
        normalized
    end
  end

  defp maybe_put_expected_sha256(normalized, sync) do
    case value(sync, :expected_sha256) do
      nil -> normalized
      expected -> Map.put(normalized, :expected_sha256, expected)
    end
  end

  defp maybe_put_operation_id(normalized, sync) do
    case value(sync, :operation_id) do
      nil -> normalized
      operation_id -> Map.put(normalized, :operation_id, operation_id)
    end
  end

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
      is_binary(sync.reason) or is_nil(sync.reason),
      valid_expected_sha256?(sync),
      valid_operation_id?(sync)
    ])
  end

  defp valid_expected_sha256?(%{status: "applying", expected_sha256: value}),
    do: valid_sha256?(value)

  defp valid_expected_sha256?(%{status: "applying"}), do: false
  defp valid_expected_sha256?(sync), do: not Map.has_key?(sync, :expected_sha256)

  defp valid_operation_id?(%{status: "applying", operation_id: value}),
    do: is_binary(value) and Regex.match?(~r/\A[A-Za-z0-9_-]{22}\z/, value)

  defp valid_operation_id?(%{status: "applying"}), do: false
  defp valid_operation_id?(sync), do: not Map.has_key?(sync, :operation_id)

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
