defmodule Cinder.Subtitles.Manifest do
  @moduledoc false

  require Logger

  import Cinder.Subtitles.SafeFile,
    only: [check_destination: 1, fs: 0, safe_destination: 1, safe_remove: 1]

  # `own_track`: the video's own full subtitle track in that language, extracted by
  # `Cinder.Subtitles` in preference to a download (spec 069). `embedded` is the older last-resort
  # extraction when OpenSubtitles has nothing, which stays open to a later download. Both record
  # the moviehash of the file they came out of (`source_moviehash`); an embedded one also records
  # the index of the track it came from (`source_track`).
  @origins ~w(opensubtitles_hash opensubtitles_id own_track embedded translated release_sidecar)
  # The origins `Cinder.Subtitles.Sync` handles (`sync_origin?/2`).
  @sync_origins ~w(opensubtitles_hash opensubtitles_id own_track)
  @sync_statuses ~w(aligned review applying)
  # `native`: the timing rules on the video's own track, with no alignment to run.
  @sync_methods ~w(embedded audio native manual)
  @sidecar_extensions ~w(.srt .ass .ssa .sub .vtt)
  @sha256 ~r/\A[0-9a-f]{64}\z/
  @manifest_suffix ".cinder-subtitles.json"
  # A track's fields that `Cinder.Subtitles.SidecarTransaction` owns, as `normalize_tracks/1` reads
  # them: each record, or the flag that it did not decode.
  @transaction_fields ~w(
    sync sync_invalid?
    replacement_cleanup_sync replacement_cleanup_sync_invalid?
    reset_cleanup_sync reset_cleanup_sync_invalid?
    backup_tombstone backup_tombstone_invalid?
  )a
  # The flags `normalize_tracks/1` sets on a record that did not decode. A file or digest that
  # did not decode leaves no `file` or `managed_sha256` field, which `syncable?/2` needs anyway.
  @invalid_record_markers ~w(
    sync_invalid? replacement_cleanup_sync_invalid? reset_cleanup_sync_invalid?
    backup_tombstone_invalid?
  )a

  @spec path(String.t()) :: String.t()
  def path(video_path) do
    Path.join(
      Path.dirname(video_path),
      "." <> Path.basename(video_path) <> @manifest_suffix
    )
  end

  @doc "The video whose manifest `path/1` puts at `manifest_path`, or nil for any other name."
  @spec video_path(String.t()) :: String.t() | nil
  def video_path(manifest_path) do
    with "." <> name <- Path.basename(manifest_path),
         video when video != "" <- String.replace_suffix(name, @manifest_suffix, ""),
         true <- video != name do
      Path.join(Path.dirname(manifest_path), video)
    else
      _other -> nil
    end
  end

  @doc """
  The manifest of `video_path` for a caller that only reads it: `load/1`'s, or an empty one when
  `load/1` cannot read it.
  """
  @spec read(String.t()) :: %{video_moviehash: String.t() | nil, tracks: map()}
  def read(video_path) do
    case load(video_path) do
      {:ok, state} -> state
      {:error, {:unreadable_manifest, _reason}} -> empty()
    end
  end

  @doc """
  The manifest of `video_path` for a caller that writes from what it reads. A missing manifest
  reads as an empty one. So does a malformed one, with a warning: a retry cannot repair it, and
  refusing would block every later write for the video. A manifest file whose read returns an
  error other than `:enoent` is `{:error, {:unreadable_manifest, reason}}`, with one warning
  naming the video and the reason: starting from an empty state there would drop every other
  language's record (#1202).

  A failed `lstat` other than `:enoent` while checking the manifest's path is the same error and
  warning, with the `lstat` reason: the check could not tell whether the manifest is there (#1210).
  A manifest path the check refuses (a symlink on the way, a path outside every video root) still
  reads as an empty one, silently: `write/2` refuses that path too, so no writer can replace the
  manifest there and no record is lost.
  """
  @spec load(String.t()) ::
          {:ok, %{video_moviehash: String.t() | nil, tracks: map()}}
          | {:error, {:unreadable_manifest, term()}}
  def load(video_path) do
    case check_destination(path(video_path)) do
      {:ok, manifest_path} -> load_manifest(manifest_path, video_path)
      {:error, {:lstat, reason}} -> unreadable(video_path, reason)
      {:error, :unsafe_destination} -> {:ok, empty()}
    end
  end

  defp load_manifest(manifest_path, video_path) do
    case fs().read(manifest_path) do
      {:ok, json} -> {:ok, decode(json, video_path)}
      {:error, :enoent} -> {:ok, empty()}
      {:error, reason} -> unreadable(video_path, reason)
    end
  end

  defp unreadable(video_path, reason) do
    Logger.warning("subtitle manifest cannot be read for #{video_path}: #{inspect(reason)}")
    {:error, {:unreadable_manifest, reason}}
  end

  @doc """
  The manifest of `video_path` as `read/1` decodes it, telling a missing manifest, which reads as
  an empty one, from one it cannot read (`{:error, reason}`) or decode (`{:error, :malformed}`).
  Logs nothing.
  """
  @spec fetch(String.t()) ::
          {:ok, %{video_moviehash: String.t() | nil, tracks: map()}} | {:error, term()}
  def fetch(video_path) do
    with {:ok, manifest_path} <- safe_destination(path(video_path)) do
      case fs().read(manifest_path) do
        {:ok, json} -> decode_state(json)
        {:error, :enoent} -> {:ok, empty()}
        {:error, _reason} = error -> error
      end
    end
  end

  @spec put(
          String.t(),
          String.t() | nil,
          String.t(),
          String.t() | atom(),
          String.t() | nil,
          String.t() | nil,
          map() | nil,
          non_neg_integer() | nil
        ) ::
          :ok | {:error, term()}
  def put(
        video_path,
        moviehash,
        language,
        origin,
        sidecar_path \\ nil,
        managed_sha256 \\ nil,
        replacement_cleanup_sync \\ nil,
        source_track \\ nil
      ) do
    with {:ok, file} <- normalize_put_file(video_path, sidecar_path),
         {:ok, managed_sha256} <- normalize_put_sha256(managed_sha256),
         {:ok, replacement_cleanup_sync} <- normalize_put_sync(replacement_cleanup_sync),
         {:ok, source_track} <- normalize_put_source_track(source_track),
         {:ok, state} <- load(video_path) do
      track = %{origin: to_string(origin)}
      track = if file, do: Map.put(track, :file, file), else: track
      track = if managed_sha256, do: Map.put(track, :managed_sha256, managed_sha256), else: track
      track = Map.merge(track, source(to_string(origin), moviehash, source_track))

      track =
        if replacement_cleanup_sync,
          do: Map.put(track, :replacement_cleanup_sync, replacement_cleanup_sync),
          else: track

      track =
        case get_in(state, [:tracks, language, :backup_tombstone]) do
          nil -> track
          tombstone -> Map.put(track, :backup_tombstone, tombstone)
        end

      state =
        state
        |> put_in([:tracks, language], track)
        |> Map.put(:video_moviehash, moviehash || state.video_moviehash)

      write(video_path, state)
    end
  end

  # An own or embedded track belongs to the file it came out of: the manifest-wide hash is
  # rewritten by every language's write, so after an upgrade at the same path it would vouch for a
  # track extracted from the replaced file. An embedded track stays open to a download (`stable?/3`
  # ignores its source hash); the hash only spares the next sweep an extraction whose result it
  # already holds (#861). Its track index lets that sweep still try the tracks ranked ahead of it
  # (#1071); without the hash, nothing could tell it is the same file.
  defp source("own_track", moviehash, _track) when is_binary(moviehash),
    do: %{source_moviehash: moviehash}

  defp source("embedded", moviehash, nil) when is_binary(moviehash),
    do: %{source_moviehash: moviehash}

  defp source("embedded", moviehash, track) when is_binary(moviehash),
    do: %{source_moviehash: moviehash, source_track: track}

  defp source(_origin, _moviehash, _track), do: %{}

  @spec put_sync(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def put_sync(video_path, language, sync) do
    with {:ok, state} <- load(video_path),
         {:ok, sync} <- normalize_sync(sync),
         %{origin: _origin} = track <- get_in(state, [:tracks, language]) do
      track = track |> Map.delete(:sync_invalid?) |> Map.put(:sync, sync)
      write(video_path, put_in(state, [:tracks, language], track))
    else
      nil -> {:error, :unknown_track}
      :error -> {:error, :invalid_sync}
      {:error, _reason} = error -> error
    end
  end

  @spec clear_sync(String.t(), String.t()) :: :ok | {:error, term()}
  def clear_sync(video_path, language),
    do: drop_fields(video_path, language, [:sync, :sync_invalid?])

  # Drops `fields` from `language`'s track. A manifest without that track has nothing to drop.
  defp drop_fields(video_path, language, fields) do
    with {:ok, state} <- load(video_path) do
      case get_in(state, [:tracks, language]) do
        %{origin: _origin} = track ->
          write(video_path, put_in(state, [:tracks, language], Map.drop(track, fields)))

        nil ->
          :ok
      end
    end
  end

  @spec replacement_cleanup_sync(map(), String.t()) :: map() | nil
  def replacement_cleanup_sync(state, language),
    do: get_in(state, [:tracks, language, :replacement_cleanup_sync])

  @spec begin_replacement_cleanup(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def begin_replacement_cleanup(video_path, language, sync) do
    with {:ok, state} <- load(video_path),
         {:ok, sync} <- normalize_sync(sync),
         %{origin: _origin} = track <- get_in(state, [:tracks, language]) do
      track =
        track
        |> Map.drop([:sync, :sync_invalid?])
        |> Map.put(:replacement_cleanup_sync, sync)

      write(video_path, put_in(state, [:tracks, language], track))
    else
      nil -> {:error, :unknown_track}
      :error -> {:error, :invalid_replacement_cleanup_sync}
      {:error, _reason} = error -> error
    end
  end

  @spec clear_replacement_cleanup(String.t(), String.t()) :: :ok | {:error, term()}
  def clear_replacement_cleanup(video_path, language),
    do: drop_fields(video_path, language, [:replacement_cleanup_sync])

  @spec begin_reset_cleanup(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def begin_reset_cleanup(video_path, language, sync) do
    with {:ok, state} <- load(video_path),
         {:ok, sync} <- normalize_put_sync(sync),
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
    with {:ok, state} <- load(video_path),
         {:ok, sync} <- normalize_sync(sync),
         %{origin: _origin} = track <- get_in(state, [:tracks, language]) do
      track =
        track
        |> Map.drop([:sync_invalid?, :reset_cleanup_sync])
        |> Map.put(:sync, sync)

      write(video_path, put_in(state, [:tracks, language], track))
    else
      nil -> {:error, :unknown_track}
      :error -> {:error, :invalid_sync}
      {:error, _reason} = error -> error
    end
  end

  @spec finish_reset_cleanup(String.t(), String.t()) :: :ok | {:error, term()}
  def finish_reset_cleanup(video_path, language),
    do: drop_fields(video_path, language, [:sync, :sync_invalid?, :reset_cleanup_sync])

  @spec backup_tombstone(map(), String.t()) :: map() | nil
  def backup_tombstone(state, language),
    do: get_in(state, [:tracks, language, :backup_tombstone])

  @spec put_backup_tombstone(String.t(), String.t(), term()) :: :ok | {:error, term()}
  def put_backup_tombstone(video_path, language, identity) do
    with {:ok, state} <- load(video_path),
         {:ok, tombstone} <- normalize_backup_tombstone(%{identity: identity}),
         %{origin: _origin} = track <- get_in(state, [:tracks, language]) do
      write(
        video_path,
        put_in(state, [:tracks, language], Map.put(track, :backup_tombstone, tombstone))
      )
    else
      nil -> {:error, :unknown_track}
      :error -> {:error, :invalid_backup_tombstone}
      {:error, _reason} = error -> error
    end
  end

  @spec sync(map(), String.t()) :: map() | nil
  def sync(state, language), do: get_in(state, [:tracks, language, :sync])

  @doc """
  Removes `language`'s track from the manifest of `video_path`, so its sidecar is no longer
  managed. It removes only a track whose origin is `origin` and that holds no record of
  `Cinder.Subtitles.SidecarTransaction` (a final or pending record, a cleanup journal or a backup
  tombstone, valid or not): those fields are that module's to clear. The rest of the manifest stays
  as it was. A refusal writes nothing:

    * `{:error, :unknown_track}` when the manifest has no track for `language`;
    * `{:error, {:origin, other}}` when the track's origin is another one;
    * `{:error, {:transaction_records, fields}}` naming the fields the track holds.

  A manifest `load/1` cannot read, and a failed write, return their error. A rename the
  filesystem did not acknowledge, and whose result a read cannot confirm, returns its error even
  when the manifest without the track is already in place.
  """
  @spec delete_track(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def delete_track(video_path, language, origin) do
    with {:ok, state} <- load(video_path),
         {:ok, track} <- fetch_track(state, language),
         :ok <- deletable(track, origin) do
      write(video_path, %{state | tracks: Map.delete(state.tracks, language)})
    end
  end

  defp fetch_track(state, language) do
    case Map.fetch(state.tracks, language) do
      {:ok, track} -> {:ok, track}
      :error -> {:error, :unknown_track}
    end
  end

  defp deletable(%{origin: origin} = track, origin) do
    case Enum.filter(@transaction_fields, &Map.has_key?(track, &1)) do
      [] -> :ok
      fields -> {:error, {:transaction_records, fields}}
    end
  end

  defp deletable(%{origin: other}, _origin), do: {:error, {:origin, other}}

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
    case get_in(state, [:tracks, language]) do
      %{origin: "own_track"} = track -> Map.get(track, :source_moviehash) == moviehash
      _track -> state.video_moviehash == moviehash and verified?(state, language)
    end
  end

  def stable?(_state, _moviehash, _language), do: false

  # The index of the track the language's embedded sidecar was extracted from, when it came out
  # of the file `moviehash` identifies and recorded one; nil otherwise.
  @spec embedded_track(map(), String.t() | nil, String.t()) :: non_neg_integer() | nil
  def embedded_track(state, moviehash, language) when is_binary(moviehash) do
    case state.tracks[language] do
      %{origin: "embedded", source_moviehash: ^moviehash, source_track: index} -> index
      _track -> nil
    end
  end

  def embedded_track(_state, _moviehash, _language), do: nil

  @spec managed?(map(), String.t()) :: boolean()
  def managed?(state, language), do: origin(state, language) in @origins

  # Hash-verified origin regardless of whether the stored moviehash still matches — callers that
  # can't compute a current hash use this to avoid downgrading a verified entry they can't check.
  # The video's own track is verified by construction: it came out of that very file.
  @spec verified?(map(), String.t()) :: boolean()
  def verified?(state, language), do: origin(state, language) in ~w(opensubtitles_hash own_track)

  @doc "The origin of `language`'s entry, or nil when the manifest has none."
  @spec origin(map(), String.t()) :: String.t() | nil
  def origin(state, language), do: get_in(state, [:tracks, language, :origin])

  @doc "Whether the manifest has no entry at all."
  @spec empty?(map()) :: boolean()
  def empty?(state), do: state.tracks == %{}

  @doc """
  Whether `language`'s entry has an origin `Cinder.Subtitles.Sync` handles: an OpenSubtitles
  download or the video's own track, as opposed to an embedded extraction, a translation or a
  release sidecar.
  """
  @spec sync_origin?(map(), String.t()) :: boolean()
  def sync_origin?(state, language), do: origin(state, language) in @sync_origins

  @doc """
  Whether `Cinder.Subtitles.Sync` may handle `language`'s entry: a `sync_origin?/2` entry that
  records its sidecar file and the digest Cinder wrote, with no file, digest or record that failed
  to decode: a file or digest that did not decode leaves no `file` or `managed_sha256` field, and a
  record that did not decode leaves its `*_invalid?` marker.
  """
  @spec syncable?(map(), String.t()) :: boolean()
  def syncable?(state, language) do
    case entry(state, language) do
      %{file: _file, managed_sha256: _digest} = entry ->
        sync_origin?(state, language) and
          not Enum.any?(@invalid_record_markers, &Map.has_key?(entry, &1))

      _none ->
        false
    end
  end

  @doc """
  The language of the one entry that records `basename` as its sidecar file, or `:error` when no
  entry or several entries record it. The language is the entry's key, the wanted code a fetch
  wrote it under. A file that did not decode is recorded by no entry.
  """
  @spec language_for_file(map(), String.t()) :: {:ok, String.t()} | :error
  def language_for_file(state, basename) do
    case for({language, %{file: ^basename}} <- state.tracks, do: language) do
      [language] -> {:ok, language}
      _none_or_several -> :error
    end
  end

  @doc """
  The fields of `language`'s entry that a `Cinder.Subtitles.Sync` item carries, each nil when the
  entry has none. `Cinder.Subtitles.SidecarTransaction` owns the records among them and reads
  them from the item.
  """
  @spec sync_item(map(), String.t()) :: %{
          origin: String.t() | nil,
          source_moviehash: String.t() | nil,
          managed_sha256: String.t() | nil,
          sync: map() | nil,
          reset_cleanup_sync: map() | nil,
          backup_tombstone: map() | nil
        }
  def sync_item(state, language) do
    entry = entry(state, language) || %{}

    Map.new(
      ~w(origin source_moviehash managed_sha256 sync reset_cleanup_sync backup_tombstone)a,
      &{&1, Map.get(entry, &1)}
    )
  end

  @doc "Whether `language`'s sync record decoded and is the operator's manual retime."
  @spec manual_sync?(map(), String.t()) :: boolean()
  def manual_sync?(state, language),
    do: match?(%{sync: %{method: "manual"}}, entry(state, language))

  # The records only `Cinder.Subtitles.Sync` writes, decoded or not: a final or pending sync
  # record and a reset's cleanup journal. A backup tombstone and a replacement's cleanup journal
  # come with a fetched replacement, so they are left out on purpose.
  @sync_records [:sync, :sync_invalid?, :reset_cleanup_sync, :reset_cleanup_sync_invalid?]

  @doc """
  Whether `language`'s entry holds a record that only `Cinder.Subtitles.Sync` writes, valid or
  not: a sync record or a reset's cleanup journal. A backup tombstone or a replacement's cleanup
  journal alone does not count: a fetched replacement writes them.
  """
  @spec sync_record?(map(), String.t()) :: boolean()
  def sync_record?(state, language) do
    entry = entry(state, language) || %{}
    Enum.any?(@sync_records, &Map.has_key?(entry, &1))
  end

  @doc """
  Whether `language`'s entry holds a reset's or a replacement's cleanup journal that decoded: a
  recovery `Cinder.Subtitles.SidecarTransaction` has yet to finish.
  """
  @spec cleanup_journal?(map(), String.t()) :: boolean()
  def cleanup_journal?(state, language) do
    entry = entry(state, language) || %{}
    is_map_key(entry, :reset_cleanup_sync) or is_map_key(entry, :replacement_cleanup_sync)
  end

  @doc """
  Whether `sha256` names bytes Cinder last wrote for `language`: the digest it recorded, or the
  `applied_sha256` of the entry's sync record. An entry without a recorded digest that decoded
  matches nothing. A nil `sha256` (a sidecar that could not be read) never matches, since both
  digests decode only as hex strings.
  """
  @spec written?(map(), String.t(), String.t() | nil) :: boolean()
  def written?(state, language, sha256) do
    case entry(state, language) do
      %{managed_sha256: ^sha256} -> true
      %{managed_sha256: _digest, sync: %{applied_sha256: ^sha256}} -> true
      _other -> false
    end
  end

  defp entry(state, language), do: Map.get(state.tracks, language)

  defp decode(json, video_path) do
    case decode_state(json) do
      {:ok, state} ->
        state

      {:error, :malformed} ->
        Logger.warning("subtitle manifest is malformed for #{video_path}")
        empty()
    end
  end

  defp decode_state(json) do
    with {:ok, %{"video_moviehash" => moviehash, "tracks" => tracks}}
         when is_map(tracks) <- Jason.decode(json),
         true <- is_binary(moviehash) or is_nil(moviehash),
         {:ok, tracks} <- normalize_tracks(tracks) do
      {:ok, %{video_moviehash: moviehash, tracks: tracks}}
    else
      _ -> {:error, :malformed}
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
          |> Map.merge(normalize_optional_source_moviehash(track))
          |> Map.merge(normalize_optional_source_track(track))

        {:cont, {:ok, Map.put(acc, language, normalized)}}

      _, _ ->
        {:halt, :error}
    end)
  end

  defp normalize_optional_source_moviehash(%{"source_moviehash" => moviehash})
       when is_binary(moviehash),
       do: %{source_moviehash: moviehash}

  defp normalize_optional_source_moviehash(_track), do: %{}

  # Anything else reads as no recorded track, which costs one extraction, not the manifest.
  defp normalize_optional_source_track(%{"source_track" => index})
       when is_integer(index) and index >= 0,
       do: %{source_track: index}

  defp normalize_optional_source_track(_track), do: %{}

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

  defp normalize_put_source_track(nil), do: {:ok, nil}

  defp normalize_put_source_track(index) when is_integer(index) and index >= 0,
    do: {:ok, index}

  defp normalize_put_source_track(_index), do: {:error, :invalid_source_track}

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
      |> maybe_put_piecewise(sync)
      # Whether the timing rules had the video's shot changes. Absent on results from before cuts
      # were known, which a later request that knows them redoes.
      |> then(
        &if(value(sync, :shot_changes) == true, do: Map.put(&1, :shot_changes, true), else: &1)
      )

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

  # A piecewise alignment's segment count and largest applied shift, both optional: pre-piecewise
  # tracks never carried them, and a single-segment alignment is fully described by `offset_ms`.
  # Unusable values are dropped rather than quarantining the whole track — they are descriptive
  # only, and no decision reads them.
  defp maybe_put_piecewise(normalized, sync) do
    case {value(sync, :segments), value(sync, :max_offset_ms)} do
      {segments, max_offset_ms}
      when is_integer(segments) and segments > 1 and is_integer(max_offset_ms) and
             max_offset_ms >= 0 ->
        Map.merge(normalized, %{segments: segments, max_offset_ms: max_offset_ms})

      _ ->
        normalized
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

  defp empty, do: %{video_moviehash: nil, tracks: %{}}
end
