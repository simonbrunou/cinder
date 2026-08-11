defmodule Cinder.Subtitles.Sync do
  @moduledoc """
  Synchronizes only sidecars recorded as OpenSubtitles downloads in Cinder's adjacent manifest.

  Filesystem mutations are contained by `Cinder.Library.PathPolicy`; public UI actions resolve a
  server-generated item ID back through discovery instead of accepting paths from the client.
  """

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Season}
  alias Cinder.Library.{PathPolicy, Sidecars}
  alias Cinder.Repo
  alias Cinder.Settings
  alias Cinder.Subtitles.{Manifest, Moviehash}
  alias Cinder.Subtitles.Sync.Timing

  @managed_origins ~w(opensubtitles_hash opensubtitles_id)

  @type item :: %{
          required(:id) => String.t(),
          required(:video_path) => String.t(),
          required(:sidecar_path) => String.t(),
          required(:language) => String.t(),
          required(:origin) => String.t(),
          required(:label) => String.t(),
          optional(:sync) => map() | nil
        }

  @doc "Manifest-managed OpenSubtitles sidecars belonging to one video."
  @spec discover(String.t()) :: [item()]
  def discover(video_path) do
    state = Manifest.read(video_path)

    video_path
    |> Sidecars.files()
    |> Enum.flat_map(fn {sidecar_path, language} ->
      track = get_in(state, [:tracks, language])

      if track && track.origin in @managed_origins && syncable_track?(track) &&
           tracked_sidecar?(track, video_path, sidecar_path, language) do
        [item(video_path, sidecar_path, language, track)]
      else
        []
      end
    end)
    |> Enum.sort_by(&{&1.language, &1.sidecar_path})
  end

  @doc "Returns discoverable sidecars for a server-side catalog scope."
  @spec items(:library | {:movie | :series | :season | :episode, pos_integer()}) :: [item()]
  def items(scope \\ :library), do: scope |> units() |> Enum.flat_map(&discover(&1.video_path))

  @doc "Returns deduplicated videos for a server-side catalog scope."
  @spec units(:library | {:movie | :series | :season | :episode, pos_integer()}) :: [map()]
  def units(:library) do
    movie_units =
      for movie <- Catalog.list_available_movies_with_file(),
          do: unit(movie.file_path, movie.title)

    episode_units =
      for episode <- Catalog.list_episodes_with_file(),
          path <- Episode.file_paths(episode),
          do: unit(path, episode_label(episode))

    dedupe_units(movie_units ++ episode_units)
  end

  def units({:movie, id}) do
    case Catalog.get_movie_by_id(id) do
      %{file_path: path, title: title} when is_binary(path) -> [unit(path, title)]
      _ -> []
    end
  end

  def units({:series, id}) do
    case Catalog.get_series_with_tree(id) do
      nil -> []
      series -> series_units(series)
    end
  end

  def units({:season, id}) do
    case Repo.get(Season, id) |> preload_episodes() do
      nil -> []
      season -> episode_units(season.episodes)
    end
  end

  def units({:episode, id}) do
    case Repo.get(Episode, id) |> preload_episode() do
      nil -> []
      episode -> episode_units([episode])
    end
  end

  @doc "Runs automatic analysis for every managed sidecar belonging to a video."
  @spec analyze_video(String.t()) :: [map()]
  def analyze_video(video_path) do
    :global.trans({{Cinder.Subtitles, video_path}, self()}, fn ->
      do_analyze_video(video_path)
    end)
  end

  defp do_analyze_video(video_path) do
    moviehash = current_moviehash(video_path)
    items = Enum.map(discover(video_path), &prepare_replacement(&1, moviehash))

    {reference, reference_path} =
      if Enum.any?(items, &(not Map.has_key?(&1, :auto_review_reason))),
        do: embedded_reference(video_path),
        else: {:audio, nil}

    try do
      Enum.map(items, &analyze_item(&1, moviehash, reference, reference_path))
    after
      if reference_path, do: safe_remove(reference_path)
    end
  end

  @doc "Current sidecar fingerprint for binding a manual preview to the bytes it described."
  @spec fingerprint(item()) :: {:ok, String.t()} | {:error, term()}
  def fingerprint(%{video_path: video_path, id: id}) do
    :global.trans({{Cinder.Subtitles, video_path}, self()}, fn ->
      with {:ok, item} <- resolve(video_path, id),
           hash when is_binary(hash) <- file_sha256(item.sidecar_path),
           do: {:ok, hash},
           else: (_ -> {:error, :unreadable_sidecar})
    end)
  end

  def fingerprint(_item), do: {:error, :unknown_item}

  @doc "Applies a direct affine correction, always reusing the immutable original when present."
  @spec manual(item(), integer(), number(), String.t() | nil) ::
          {:ok, :aligned | :corrected, item()} | {:error, term()}
  def manual(item, offset_ms, rate, expected_sha256 \\ nil)

  def manual(%{video_path: video_path, id: id}, offset_ms, rate, expected_sha256)
      when is_integer(offset_ms) and is_number(rate) and rate > 0 do
    :global.trans({{Cinder.Subtitles, video_path}, self()}, fn ->
      with {:ok, item} <- resolve(video_path, id),
           :ok <- verify_expected(item, expected_sha256) do
        apply_manual(item, current_moviehash(video_path), offset_ms, rate)
      end
    end)
  end

  def manual(_item, _offset_ms, _rate, _expected_sha256),
    do: {:error, :invalid_adjustment}

  @doc "Applies an affine correction derived from one or two sidecar→video timestamp anchors."
  @spec manual_from_anchors(item(), [{integer(), integer()}]) ::
          {:ok, :aligned | :corrected, item()} | {:error, term()}
  def manual_from_anchors(item, anchors) do
    with {:ok, {offset_ms, rate}} <- Timing.from_anchors(anchors),
         do: manual(item, offset_ms, rate)
  end

  @doc "Restores the immutable original and clears correction metadata."
  @spec reset(item()) :: :ok | {:error, term()}
  def reset(%{video_path: video_path, id: id}) do
    :global.trans({{Cinder.Subtitles, video_path}, self()}, fn ->
      with {:ok, item} <- resolve(video_path, id) do
        item |> prepare_replacement(current_moviehash(video_path)) |> reset_item()
      end
    end)
  end

  def reset(_item), do: {:error, :unknown_item}

  @doc "Hidden original adjacent to a corrected sidecar."
  @spec backup_path(String.t()) :: String.t()
  def backup_path(sidecar_path) do
    Path.join(
      Path.dirname(sidecar_path),
      ".#{Path.basename(sidecar_path)}.cinder-sync-original"
    )
  end

  @doc false
  def discard_replacement(sidecar_path) do
    backup = backup_path(sidecar_path)
    if regular_file?(backup), do: safe_remove(backup)
    :ok
  end

  defp analyze_item(%{auto_review_reason: reason} = item, _moviehash, _reference, _path),
    do: record_blocked_review(item, reason)

  defp analyze_item(%{sync: %{status: "aligned"}} = item, moviehash, _reference, _path) do
    if current_sync?(item, moviehash) do
      result(item, :aligned, item.sync.method, item.sync)
    else
      analyze_item(%{item | sync: nil}, moviehash, nil, nil)
    end
  end

  defp analyze_item(item, moviehash, :embedded, reference_path) do
    case run_engine(item, moviehash, "embedded", reference_path) do
      %{status: :review} -> analyze_item(item, moviehash, :audio, item.video_path)
      %{status: :failed} -> analyze_item(item, moviehash, :audio, item.video_path)
      result -> result
    end
  end

  defp analyze_item(item, moviehash, _reference, _reference_path),
    do: run_engine(item, moviehash, "audio", item.video_path)

  defp run_engine(item, moviehash, method, reference_path) do
    output =
      temporary(item.sidecar_path, ".cinder-subtitle-sync-", Path.extname(item.sidecar_path))

    try do
      with {:ok, output} <- safe_destination(output),
           :ok <- fs().write_exclusive(output, "") do
        invoke_engine(item, moviehash, method, reference_path, output)
      else
        {:error, reason} -> result(item, :failed, method, %{reason: reason})
      end
    after
      safe_remove(output)
    end
  end

  defp invoke_engine(item, moviehash, method, reference_path, output) do
    case engine().sync(reference_path, item.sidecar_path, output) do
      {:ok, metrics} -> apply_engine_output(item, moviehash, method, output, metrics)
      {:review, metrics} -> record_review(item, moviehash, method, metrics)
      {:error, _reason} -> record_review(item, moviehash, method, %{reason: :engine_failed})
    end
  end

  defp apply_engine_output(item, moviehash, method, output, metrics) do
    with {:ok, source} <- safe_read(item.sidecar_path),
         {:ok, adjusted} <- safe_read(output) do
      if source == adjusted or insignificant_correction?(metrics) do
        record_aligned(item, moviehash, method, source, source, metrics, :aligned)
      else
        apply_correction(item, moviehash, method, source, adjusted, metrics)
      end
    else
      {:error, reason} -> result(item, :failed, method, %{reason: reason})
    end
  end

  defp apply_correction(item, moviehash, method, source, adjusted, metrics) do
    with {:ok, backup_created?} <- ensure_backup(item.sidecar_path),
         :ok <- atomic_write(item.sidecar_path, adjusted) do
      metadata = metadata("aligned", method, moviehash, source, adjusted, metrics)

      case Manifest.put_sync(item.video_path, item.language, metadata) do
        :ok ->
          result(%{item | sync: metadata}, :corrected, method, metadata)

        {:error, reason} ->
          manifest_failure(item, source, adjusted, backup_created?, method, reason)
      end
    else
      {:error, reason} -> result(item, :failed, method, %{reason: reason})
    end
  end

  defp record_aligned(item, moviehash, method, source, adjusted, metrics, status) do
    metadata = metadata("aligned", method, moviehash, source, adjusted, metrics)

    case Manifest.put_sync(item.video_path, item.language, metadata) do
      :ok -> result(%{item | sync: metadata}, status, method, metadata)
      {:error, reason} -> result(item, :failed, method, %{reason: {:manifest, reason}})
    end
  end

  defp record_review(item, moviehash, method, metrics) do
    case safe_read(item.sidecar_path) do
      {:ok, source} ->
        metadata = metadata("review", method, moviehash, source, source, metrics)

        case Manifest.put_sync(item.video_path, item.language, metadata) do
          :ok -> result(%{item | sync: metadata}, :review, method, metadata)
          {:error, reason} -> result(item, :failed, method, %{reason: {:manifest, reason}})
        end

      {:error, reason} ->
        result(item, :failed, method, %{reason: reason})
    end
  end

  defp record_blocked_review(%{sync: nil} = item, reason) do
    result(item, :review, "replacement", %{reason: Atom.to_string(reason)})
  end

  defp record_blocked_review(item, reason) do
    metadata = %{item.sync | status: "review", reason: Atom.to_string(reason)}

    case Manifest.put_sync(item.video_path, item.language, metadata) do
      :ok ->
        result(%{item | sync: metadata}, :review, metadata.method, metadata)

      {:error, manifest_reason} ->
        result(item, :failed, metadata.method, %{reason: {:manifest, manifest_reason}})
    end
  end

  defp apply_manual(item, moviehash, offset_ms, rate) do
    item = prepare_replacement(item, moviehash)

    case item do
      %{auto_review_reason: reason} -> {:error, reason}
      _ -> apply_ready_manual(item, moviehash, offset_ms, rate)
    end
  end

  defp apply_ready_manual(item, moviehash, offset_ms, rate) do
    source_path =
      if regular_file?(backup_path(item.sidecar_path)),
        do: backup_path(item.sidecar_path),
        else: item.sidecar_path

    with {:ok, source} <- safe_read(source_path),
         {:ok, current} <- safe_read(item.sidecar_path),
         {:ok, adjusted} <-
           Timing.retime(source, Path.extname(item.sidecar_path), offset_ms, rate) do
      status = if adjusted == current, do: :aligned, else: :corrected

      persist_manual(item, moviehash, source, current, adjusted, offset_ms, rate, status)
    end
  end

  defp persist_manual(item, moviehash, source, _current, adjusted, offset_ms, rate, :aligned) do
    metadata =
      metadata("aligned", "manual", moviehash, source, adjusted, %{
        offset_ms: offset_ms,
        rate: rate
      })

    case Manifest.put_sync(item.video_path, item.language, metadata) do
      :ok -> {:ok, :aligned, %{item | sync: metadata}}
      {:error, reason} -> {:error, {:manifest, reason}}
    end
  end

  defp persist_manual(item, moviehash, source, current, adjusted, offset_ms, rate, :corrected) do
    with {:ok, backup_created?} <- ensure_backup(item.sidecar_path),
         :ok <- atomic_write(item.sidecar_path, adjusted) do
      metadata =
        metadata("aligned", "manual", moviehash, source, adjusted, %{
          offset_ms: offset_ms,
          rate: rate
        })

      persist_manual_correction(item, current, adjusted, backup_created?, metadata)
    end
  end

  defp persist_manual_correction(item, current, adjusted, backup_created?, metadata) do
    case Manifest.put_sync(item.video_path, item.language, metadata) do
      :ok -> {:ok, :corrected, %{item | sync: metadata}}
      {:error, reason} -> rollback_manual(item, current, adjusted, backup_created?, reason)
    end
  end

  defp rollback_manual(item, current, adjusted, backup_created?, manifest_reason) do
    case rollback_correction(item, current, adjusted, backup_created?) do
      :ok ->
        {:error, {:manifest, manifest_reason}}

      {:error, rollback_reason} ->
        {:error, {:manifest_and_rollback_failed, manifest_reason, rollback_reason}}
    end
  end

  defp reset_item(item) do
    backup = backup_path(item.sidecar_path)

    with :ok <- restore_if_present(backup, item.sidecar_path),
         :ok <- Manifest.clear_sync(item.video_path, item.language),
         do: safe_remove(backup)
  end

  defp prepare_replacement(%{sync: nil} = item, _moviehash) do
    # A successful replacement drops sync metadata atomically with its provenance update. Cleanup
    # is deferred to this serialized path so ordinary subtitle commits do not add another
    # filesystem mutation, and manual actions cannot accidentally reuse the stale original.
    case safe_remove(backup_path(item.sidecar_path)) do
      :ok -> item
      {:error, _reason} -> block_replacement(item)
    end
  end

  defp prepare_replacement(item, moviehash) do
    cond do
      current_sync?(item, moviehash) ->
        item

      item.sync.moviehash == moviehash ->
        Map.put(item, :auto_review_reason, :externally_modified)

      true ->
        clean_replacement(item)
    end
  end

  defp clean_replacement(item) do
    backup = backup_path(item.sidecar_path)

    with :ok <- restore_applied_original(item, backup),
         :ok <- Manifest.clear_sync(item.video_path, item.language) do
      finish_replacement_cleanup(%{item | sync: nil}, backup)
    else
      {:error, _reason} -> block_replacement(item)
    end
  end

  defp finish_replacement_cleanup(item, backup) do
    case safe_remove(backup) do
      :ok -> item
      {:error, _reason} -> block_replacement(item)
    end
  end

  defp restore_applied_original(item, backup) do
    if file_sha256(item.sidecar_path) == item.sync.applied_sha256 and regular_file?(backup),
      do: restore_if_present(backup, item.sidecar_path),
      else: :ok
  end

  defp block_replacement(item),
    do: Map.put(item, :auto_review_reason, :replacement_cleanup_failed)

  defp current_sync?(item, moviehash) do
    current_hash = file_sha256(item.sidecar_path)

    item.sync.moviehash == moviehash and
      current_hash in [item.sync.source_sha256, item.sync.applied_sha256]
  end

  defp embedded_reference(video_path) do
    with media_info when not is_nil(media_info) <- media_info(),
         {:ok, tracks} <- media_info.subtitle_tracks(video_path) do
      find_embedded_reference(media_info, video_path, tracks)
    else
      _ -> {:audio, nil}
    end
  end

  defp find_embedded_reference(media_info, video_path, tracks) do
    tracks
    |> Enum.reject(&Map.get(&1, :forced?, false))
    |> Enum.sort_by(&Map.get(&1, :packet_count, 0), :desc)
    |> Enum.find_value({:audio, nil}, &extract_reference(media_info, video_path, &1))
  end

  defp extract_reference(media_info, video_path, track) do
    reference = temporary(video_path, ".cinder-subtitle-reference-", ".srt")

    with {:ok, content} <- media_info.extract_subtitle(video_path, track.index),
         :ok <- safe_write(reference, content) do
      {:embedded, reference}
    else
      _ ->
        safe_remove(reference)
        nil
    end
  end

  defp insignificant_correction?(metrics) do
    abs(Map.get(metrics, :offset_ms, 0)) <= 100 and
      abs(Map.get(metrics, :rate, 1.0) - 1.0) <= 0.0005
  end

  defp syncable_track?(track),
    do: not Map.get(track, :file_invalid?, false) and not Map.get(track, :sync_invalid?, false)

  defp tracked_sidecar?(%{file: file}, _video_path, sidecar_path, _language),
    do: Path.basename(sidecar_path) == file

  # Legacy manifests predate exact filenames. Cinder has historically written downloads to the
  # canonical `.language.srt` target, so fail closed rather than touching a same-language manual
  # or forced sidecar.
  defp tracked_sidecar?(_track, video_path, sidecar_path, language),
    do: sidecar_path == Path.rootname(video_path) <> ".#{language}.srt"

  defp verify_expected(_item, nil), do: :ok

  defp verify_expected(item, expected_sha256) when is_binary(expected_sha256) do
    if file_sha256(item.sidecar_path) == expected_sha256,
      do: :ok,
      else: {:error, :sidecar_changed}
  end

  defp verify_expected(_item, _expected_sha256), do: {:error, :invalid_fingerprint}

  defp resolve(video_path, id) do
    case Enum.find(discover(video_path), &(&1.id == id)) do
      nil -> {:error, :unknown_item}
      item -> {:ok, item}
    end
  end

  defp item(video_path, sidecar_path, language, track) do
    %{
      id:
        Base.url_encode64(:crypto.hash(:sha256, video_path <> <<0>> <> sidecar_path),
          padding: false
        ),
      video_path: video_path,
      sidecar_path: sidecar_path,
      language: language,
      origin: track.origin,
      sync: Map.get(track, :sync),
      label:
        "#{Path.basename(video_path)} · #{language} #{String.upcase(String.trim_leading(Path.extname(sidecar_path), "."))}"
    }
  end

  defp metadata(status, method, moviehash, source, applied, metrics) do
    %{
      status: status,
      method: method,
      moviehash: moviehash,
      source_sha256: sha256(source),
      applied_sha256: sha256(applied),
      offset_ms: Map.get(metrics, :offset_ms, 0),
      rate: Map.get(metrics, :rate, 1.0) * 1.0,
      score: Map.get(metrics, :score),
      reason: reason(Map.get(metrics, :reason))
    }
  end

  defp result(item, status, method, metadata) do
    %{
      id: item.id,
      label: item.label,
      video_path: item.video_path,
      status: status,
      method: method,
      offset_ms: Map.get(metadata, :offset_ms, 0),
      rate: Map.get(metadata, :rate, 1.0),
      score: Map.get(metadata, :score),
      reason: Map.get(metadata, :reason)
    }
  end

  defp ensure_backup(sidecar_path) do
    backup = backup_path(sidecar_path)

    with {:ok, sidecar_path} <- safe_source(sidecar_path),
         {:ok, backup} <- safe_destination(backup) do
      copy_backup(sidecar_path, backup)
    end
  end

  defp copy_backup(sidecar_path, backup) do
    case fs().cp_exclusive(sidecar_path, backup, fn _stat -> :ok end) do
      :ok -> {:ok, true}
      {:error, :eexist} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  defp manifest_failure(item, previous, adjusted, backup_created?, method, reason) do
    case rollback_correction(item, previous, adjusted, backup_created?) do
      :ok ->
        result(item, :failed, method, %{reason: {:manifest, reason}})

      {:error, rollback_reason} ->
        result(item, :failed, method, %{
          reason: {:manifest_and_rollback_failed, reason, rollback_reason}
        })
    end
  end

  defp rollback_correction(item, previous, expected_applied, backup_created?) do
    with {:ok, current} <- safe_read(item.sidecar_path),
         true <- current == expected_applied,
         :ok <- atomic_write(item.sidecar_path, previous) do
      if backup_created?, do: safe_remove(backup_path(item.sidecar_path))
      :ok
    else
      false -> {:error, :concurrent_change}
      {:error, _reason} = error -> error
    end
  end

  defp restore_if_present(backup, target) do
    if regular_file?(backup) do
      with {:ok, content} <- safe_read(backup), do: atomic_write(target, content)
    else
      :ok
    end
  end

  defp atomic_write(target, content) do
    temporary = temporary(target, ".cinder-subtitle-sync-write-", "")

    with {:ok, target} <- safe_destination(target),
         {:ok, temporary} <- safe_destination(temporary),
         :ok <- fs().write_exclusive(temporary, content) do
      result =
        with {:ok, temporary} <- safe_destination(temporary),
             {:ok, target} <- safe_destination(target),
             do: fs().rename(temporary, target)

      if result != :ok, do: safe_remove(temporary)
      result
    end
  end

  defp safe_read(path) do
    with {:ok, path} <- safe_source(path), do: fs().read(path)
  end

  defp safe_write(path, content) do
    with {:ok, path} <- safe_destination(path), do: fs().write_exclusive(path, content)
  end

  defp safe_remove(nil), do: :ok

  defp safe_remove(path) do
    with :ok <- path_policy().deletable_file(path, Settings.library_roots(), filesystem: fs()) do
      case fs().rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, _reason} = error -> error
      end
    end
  end

  defp regular_file?(path) do
    with {:ok, path} <- safe_source(path),
         {:ok, %File.Stat{type: :regular}} <- fs().lstat(path),
         do: true,
         else: (_ -> false)
  end

  defp safe_source(path) do
    path_policy().source_file(
      path,
      Settings.library_roots(),
      [String.downcase(Path.extname(path))],
      filesystem: fs()
    )
  end

  defp safe_destination(path),
    do: path_policy().destination(path, Settings.library_roots(), filesystem: fs())

  defp temporary(path, prefix, extension) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    Path.join(
      Path.dirname(path),
      "#{prefix}#{token}#{extension}"
    )
  end

  defp current_moviehash(video_path) do
    case Moviehash.of_file(video_path) do
      {:ok, moviehash} -> moviehash
      _ -> nil
    end
  end

  defp file_sha256(path) do
    case safe_read(path) do
      {:ok, content} -> sha256(content)
      _ -> nil
    end
  end

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  defp reason(nil), do: nil
  defp reason(value) when is_atom(value), do: Atom.to_string(value)
  defp reason(value) when is_binary(value), do: value
  defp reason(value), do: inspect(value)

  defp series_units(series), do: series.seasons |> Enum.flat_map(&episode_units(&1.episodes))

  defp episode_units(episodes) do
    for episode <- episodes,
        path <- Episode.file_paths(episode),
        do: unit(path, episode_label(episode))
  end

  defp unit(video_path, label), do: %{video_path: video_path, label: label}
  defp dedupe_units(units), do: Enum.uniq_by(units, & &1.video_path)

  defp episode_label(%{season: %{season_number: season}, episode_number: episode, title: title}),
    do: "S#{pad2(season)}E#{pad2(episode)} · #{title}"

  defp episode_label(%{episode_number: episode, title: title}),
    do: "E#{pad2(episode)} · #{title}"

  defp pad2(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")

  defp preload_episodes(nil), do: nil
  defp preload_episodes(season), do: Repo.preload(season, episodes: :season)
  defp preload_episode(nil), do: nil
  defp preload_episode(episode), do: Repo.preload(episode, :season)

  defp engine,
    do: Application.get_env(:cinder, :subtitle_sync_engine, Cinder.Subtitles.Sync.Ffsubsync)

  defp media_info, do: Application.get_env(:cinder, :media_info)
  defp fs, do: Application.fetch_env!(:cinder, :filesystem)
  defp path_policy, do: Application.get_env(:cinder, :path_policy, PathPolicy)
end
