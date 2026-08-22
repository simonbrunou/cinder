defmodule Cinder.Subtitles.Sync do
  @moduledoc "Synchronizes Cinder-managed adjacent subtitle sidecars."
  require Logger

  alias Cinder.Library.{Filesystem, PathPolicy, Sidecars}
  alias Cinder.Repo
  alias Cinder.Settings
  alias Cinder.Subtitles.{Manifest, Moviehash}

  alias Cinder.Subtitles.Sync.{
    AtomicFile,
    EngineWorkspace,
    Reference,
    ReplacementCleanup,
    Scope,
    Timing
  }

  @managed_origins ~w(opensubtitles_hash opensubtitles_id)
  @type item :: map()
  @doc "Manifest-managed OpenSubtitles sidecars belonging to one video."
  @spec discover(String.t()) :: [item()]
  def discover(video_path) do
    state = Manifest.read(video_path)

    sidecars = if state.tracks == %{}, do: [], else: Sidecars.files(video_path)

    sidecars
    |> Enum.flat_map(fn {sidecar_path, language} ->
      track = get_in(state, [:tracks, language])

      if track && track.origin in @managed_origins && syncable_track?(track) &&
           tracked_sidecar?(track, video_path, sidecar_path, language),
         do: [item(video_path, sidecar_path, language, track)],
         else: []
    end)
    |> Enum.sort_by(&{&1.language, &1.sidecar_path})
  end

  @doc "Returns discoverable sidecars for a server-side catalog scope."
  @spec items(:library | {:movie | :series | :season | :episode, pos_integer()}) :: [item()]
  def items(scope \\ :library), do: scope |> units() |> Enum.flat_map(&discover(&1.video_path))

  @doc "Returns deduplicated videos for a server-side catalog scope."
  @spec units(:library | {:movie | :series | :season | :episode, pos_integer()}) :: [map()]
  defdelegate units(scope), to: Scope

  @doc "Runs automatic analysis for every managed sidecar belonging to a video."
  @spec analyze_video(String.t()) :: [map()]
  def analyze_video(video_path) do
    :global.trans({{Cinder.Subtitles, video_path}, self()}, fn ->
      do_analyze_video(video_path)
    end)
  end

  defp do_analyze_video(video_path) do
    case discover(video_path) do
      [] ->
        []

      _items ->
        analyze_managed_video(video_path)
    end
  end

  defp analyze_managed_video(video_path) do
    case current_moviehash(video_path) do
      {:ok, moviehash} ->
        with :ok <- reconcile_reset_cleanups(video_path, moviehash),
             :ok <- ReplacementCleanup.reconcile(video_path) do
          do_analyze_video(video_path, moviehash)
        else
          {:error, reason} -> failed_reconciliation(video_path, reason)
        end

      {:error, _reason} ->
        moviehash_unavailable(video_path)
    end
  end

  defp failed_reconciliation(video_path, reason),
    do: Enum.map(discover(video_path), &result(&1, :failed, nil, %{reason: reason}))

  defp do_analyze_video(video_path, moviehash) do
    items = Enum.map(discover(video_path), &prepare_item(&1, moviehash))

    resolver =
      Reference.resolver(if(Enum.any?(items, &analysis_needed?/1), do: media_info()), video_path)

    Enum.map(items, fn item ->
      {reference, reference_source} = resolver.(item.language)

      analyze_item(item, moviehash, reference, reference_source)
    end)
  end

  defp analysis_needed?(%{auto_review_reason: _reason}), do: false
  defp analysis_needed?(%{sync: %{status: status}}), do: status not in ["aligned", "review"]
  defp analysis_needed?(_item), do: true

  defp prepare_item(item, moviehash),
    do: item |> reset_legacy_embedded(moviehash) |> prepare_replacement(moviehash)

  defp reset_legacy_embedded(%{sync: %{method: "embedded"} = sync} = item, moviehash) do
    if sync[:version] == 1 do
      item
    else
      with :ok <- reset_resolved(item, moviehash),
           {:ok, fresh} <- resolve(item.video_path, item.id),
           do: fresh,
           else: (_ -> Map.put(item, :auto_review_reason, :legacy_embedded_reset_failed))
    end
  end

  defp reset_legacy_embedded(item, _moviehash), do: item

  defp moviehash_unavailable(video_path) do
    Enum.map(discover(video_path), fn item ->
      result(item, :review, "identity", %{reason: "moviehash_unavailable"})
    end)
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
           :ok <- verify_expected(item, expected_sha256),
           {:ok, moviehash} <- current_moviehash(video_path) do
        apply_manual(item, moviehash, offset_ms, rate, expected_sha256)
      else
        {:error, :too_small} -> {:error, :moviehash_unavailable}
        {:error, _reason} = error -> error
      end
    end)
  end

  def manual(_item, _offset_ms, _rate, _expected_sha256),
    do: {:error, :invalid_adjustment}

  @doc "Applies a manual correction while holding a SQLite write reservation for its catalog scope."
  @spec manual_in_scope(term(), String.t(), integer(), number(), String.t()) ::
          {:ok, :aligned | :corrected, item()} | {:error, term()}
  def manual_in_scope(scope, id, offset_ms, rate, expected_sha256) do
    with_scoped_item(scope, id, fn item ->
      manual(item, offset_ms, rate, expected_sha256)
    end)
  end

  @doc "Resets a subtitle while holding a SQLite write reservation for its catalog scope."
  @spec reset_in_scope(term(), String.t()) :: :ok | {:error, term()}
  def reset_in_scope(scope, id), do: with_scoped_item(scope, id, &reset/1)

  defp with_scoped_item(scope, id, callback) do
    Repo.transaction(
      fn ->
        case Enum.find(items(scope), &(&1.id == id)) do
          nil -> Repo.rollback(:unknown_item)
          item -> callback.(item)
        end
      end,
      mode: :immediate
    )
    |> normalize_scoped_result()
  end

  defp normalize_scoped_result({:ok, result}), do: result
  defp normalize_scoped_result({:error, reason}), do: {:error, reason}

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
      with {:ok, item} <- resolve(video_path, id),
           {:ok, moviehash} <- current_moviehash(video_path) do
        reset_resolved(item, moviehash)
      else
        {:error, :too_small} -> {:error, :moviehash_unavailable}
        {:error, _reason} = error -> error
      end
    end)
  end

  def reset(_item), do: {:error, :unknown_item}

  defp reset_resolved(%{reset_cleanup_sync: %{moviehash: moviehash} = sync} = item, moviehash),
    do: complete_reset_cleanup(item, sync)

  defp reset_resolved(%{reset_cleanup_sync: %{}}, _moviehash),
    do: {:error, :reset_video_changed}

  defp reset_resolved(item, moviehash), do: reset_prepared(prepare_replacement(item, moviehash))

  defp reset_prepared(%{auto_review_reason: reason}), do: {:error, reason}
  defp reset_prepared(item), do: reset_item(item)

  @doc "Hidden original adjacent to a corrected sidecar."
  @spec backup_path(String.t()) :: String.t()
  def backup_path(sidecar_path) do
    Path.join(
      Path.dirname(sidecar_path),
      ".#{Path.basename(sidecar_path)}.cinder-sync-original"
    )
  end

  def discard_replacement(video_path, language, sidecar_path, sync) do
    backup = backup_path(sidecar_path)
    tombstone = Manifest.backup_tombstone(Manifest.read(video_path), language)

    cond do
      not active_backup?(backup) -> :ok
      is_nil(sync) -> {:error, :unexpected_backup}
      regular_file?(backup) -> retire_owned_backup(backup, sync, tombstone)
      true -> {:error, :unexpected_backup}
    end
  end

  defp analyze_item(%{auto_review_reason: reason} = item, _moviehash, _reference, _path),
    do: record_blocked_review(item, reason)

  defp analyze_item(%{sync: %{status: status}} = item, moviehash, _reference, _path)
       when status in ["aligned", "review"] do
    if current_sync?(item, moviehash) do
      result(item, String.to_existing_atom(status), item.sync.method, item.sync)
    else
      analyze_item(%{item | sync: nil}, moviehash, nil, nil)
    end
  end

  defp analyze_item(item, moviehash, :embedded, reference_path) do
    case run_engine(item, moviehash, "embedded", reference_path) do
      %{reason: reason} = result
      when reason in [
             :sidecar_changed,
             :concurrent_change,
             :video_changed,
             :moviehash_unavailable
           ] ->
        result

      %{status: :review} ->
        analyze_item(item, moviehash, :audio, item.video_path)

      %{status: :failed} ->
        analyze_item(item, moviehash, :audio, item.video_path)

      result ->
        result
    end
  end

  defp analyze_item(item, moviehash, _reference, _reference_path),
    do: run_engine(item, moviehash, "audio", item.video_path)

  defp run_engine(item, moviehash, method, {:content, content} = reference)
       when is_binary(content) do
    case safe_source(item.sidecar_path) do
      {:ok, input_path} ->
        input_path
        |> with_bound([:read, :raw, :binary], fn input ->
          invoke_bound_engine(item, moviehash, method, reference, input)
        end)
        |> normalize_engine_result(item, method)

      {:error, reason} ->
        result(item, :failed, method, %{reason: reason})
    end
  end

  defp run_engine(item, moviehash, method, reference_path) do
    with {:ok, reference_path} <- safe_source(reference_path),
         {:ok, input_path} <- safe_source(item.sidecar_path) do
      bind_engine_inputs(reference_path, input_path, fn reference, input ->
        invoke_bound_engine(item, moviehash, method, reference, input)
      end)
      |> normalize_engine_result(item, method)
    else
      {:error, reason} -> result(item, :failed, method, %{reason: reason})
    end
  end

  defp bind_engine_inputs(reference_path, input_path, callback) do
    with_bound(reference_path, [:read, :raw, :binary], fn reference ->
      with_bound(input_path, [:read, :raw, :binary], fn input ->
        callback.(reference, input)
      end)
    end)
  end

  defp normalize_engine_result({:error, reason}, item, method),
    do: result(item, :failed, method, %{reason: reason})

  defp normalize_engine_result(result, _item, _method), do: result

  defp invoke_bound_engine(item, moviehash, method, reference, input) do
    reference_extension = Path.extname(if(method == "audio", do: item.video_path, else: ".srt"))
    input_extension = Path.extname(item.sidecar_path)

    with {:ok, source} <- File.read(input.path),
         {:ok, {engine_result, output_result}} <-
           EngineWorkspace.run(
             reference,
             input,
             reference_extension,
             input_extension,
             fn reference_path,
                input_path,
                output_path,
                _output,
                reference_extension,
                input_extension ->
               engine_sync(
                 reference_path,
                 input_path,
                 output_path,
                 reference_extension,
                 input_extension
               )
             end
           ) do
      handle_engine_result(item, moviehash, method, source, engine_result, output_result)
    else
      {:error, reason} -> result(item, :failed, method, %{reason: reason})
    end
  end

  defp with_bound(path, modes, callback) do
    case fs().open_bound(path, modes) do
      {:ok, bound} -> finish_bound(bound, callback)
      {:error, _reason} = error -> error
    end
  end

  defp finish_bound(bound, callback) do
    operation =
      try do
        {:returned, callback.(bound)}
      catch
        kind, reason -> {:raised, kind, reason, __STACKTRACE__}
      end

    close_result = fs().close_bound(bound)
    finish_bound_operation(operation, close_result)
  end

  defp finish_bound_operation({:returned, result}, :ok), do: result

  defp finish_bound_operation({:returned, %{status: _status} = result}, {:error, reason}) do
    Logger.warning(
      "descriptor close failed after completed subtitle analysis: #{inspect(reason)}"
    )

    result
  end

  defp finish_bound_operation({:returned, {:committed, _result} = committed}, {:error, reason}) do
    Logger.warning(
      "descriptor close failed after committed subtitle publication: #{inspect(reason)}"
    )

    committed
  end

  defp finish_bound_operation({:returned, _result}, {:error, reason}),
    do: {:error, {:descriptor_close_failed, reason}}

  defp finish_bound_operation({:raised, kind, reason, stacktrace}, _close_result),
    do: :erlang.raise(kind, reason, stacktrace)

  defp handle_engine_result(item, moviehash, method, source, engine_result, output_result) do
    case engine_result do
      {:ok, metrics} ->
        case output_result do
          {:ok, adjusted} ->
            apply_engine_output(item, moviehash, method, source, adjusted, metrics)

          {:error, reason} ->
            result(item, :failed, method, %{reason: reason})
        end

      {:review, metrics} ->
        record_review(item, moviehash, method, source, metrics)

      {:error, _reason} ->
        record_review(item, moviehash, method, source, %{reason: :engine_failed})
    end
  end

  defp apply_engine_output(item, moviehash, method, source, adjusted, metrics) do
    with :ok <- Timing.validate(adjusted, Path.extname(item.sidecar_path)),
         :ok <- verify_analysis_inputs(item, moviehash, source) do
      apply_verified_engine_output(item, moviehash, method, source, adjusted, metrics)
    else
      {:error, :invalid_subtitle} ->
        result(item, :failed, method, %{reason: :invalid_engine_output})

      {:error, reason} ->
        result(item, :failed, method, %{reason: reason})
    end
  end

  defp apply_verified_engine_output(item, moviehash, method, source, adjusted, metrics) do
    if source == adjusted or insignificant_correction?(metrics) do
      record_aligned(item, moviehash, method, source, source, metrics, :aligned)
    else
      apply_correction(item, moviehash, method, source, adjusted, metrics)
    end
  end

  defp apply_correction(item, moviehash, method, source, adjusted, metrics) do
    metadata = metadata("aligned", method, moviehash, source, adjusted, metrics)

    case ensure_backup(item, source) do
      {:ok, backup_created?} ->
        begin_automatic_correction(
          item,
          metadata,
          source,
          adjusted,
          backup_created?,
          method
        )

      {:error, reason} ->
        result(item, :failed, method, %{reason: reason})
    end
  end

  defp begin_automatic_correction(item, metadata, source, adjusted, backup_created?, method) do
    pending =
      metadata
      |> Map.put(:status, "applying")
      |> Map.put(:expected_sha256, sha256(source))
      |> Map.put(:operation_id, operation_id())

    case verify_video_moviehash(item.video_path, metadata.moviehash) do
      :ok ->
        persist_pending_automatic(
          item,
          pending,
          metadata,
          source,
          adjusted,
          backup_created?,
          method
        )

      {:error, reason} ->
        cleanup_unpublished_correction(item, backup_created?, method, reason)
    end
  end

  defp persist_pending_automatic(
         item,
         pending,
         metadata,
         source,
         adjusted,
         backup_created?,
         method
       ) do
    case Manifest.put_sync(item.video_path, item.language, pending) do
      :ok ->
        publish_automatic_correction(
          item,
          metadata,
          source,
          adjusted,
          backup_created?,
          method,
          pending.operation_id
        )

      {:error, reason} ->
        cleanup_unpublished_correction(item, backup_created?, method, {:manifest, reason})
    end
  end

  defp publish_automatic_correction(
         item,
         metadata,
         source,
         adjusted,
         backup_created?,
         method,
         operation_id
       ) do
    case atomic_write(item.sidecar_path, adjusted, source, operation_id) do
      :ok ->
        persist_correction(item, metadata, source, adjusted, backup_created?, method)

      {:error, {:publication_committed, _detail} = reason} ->
        result(item, :failed, method, %{reason: reason})

      {:error, reason} ->
        abort_prepared_automatic(item, backup_created?, method, reason)
    end
  end

  defp abort_prepared_automatic(item, backup_created?, method, reason) do
    case abort_prepared_correction(item, backup_created?) do
      :ok ->
        result(item, :failed, method, %{reason: reason})

      {:error, cleanup_reason} ->
        result(item, :failed, method, %{reason: {:apply_abort_failed, reason, cleanup_reason}})
    end
  end

  defp persist_correction(item, metadata, source, adjusted, backup_created?, method) do
    case verify_video_moviehash(item.video_path, metadata.moviehash) do
      :ok ->
        persist_verified_correction(item, metadata, source, adjusted, backup_created?, method)

      {:error, reason} ->
        analysis_failure(item, source, adjusted, backup_created?, method, reason)
    end
  end

  defp persist_verified_correction(item, metadata, source, adjusted, backup_created?, method) do
    case Manifest.put_sync(item.video_path, item.language, metadata) do
      :ok ->
        result(%{item | sync: metadata}, :corrected, method, metadata)

      {:error, reason} ->
        manifest_failure(item, source, adjusted, backup_created?, method, reason)
    end
  end

  defp analysis_failure(item, previous, adjusted, backup_created?, method, reason) do
    case rollback_prepared_correction(item, previous, adjusted, backup_created?) do
      :ok ->
        result(item, :failed, method, %{reason: reason})

      {:error, rollback_reason} ->
        result(item, :failed, method, %{
          reason: {:analysis_and_rollback_failed, reason, rollback_reason}
        })
    end
  end

  defp record_aligned(item, moviehash, method, source, adjusted, metrics, status) do
    metadata = metadata("aligned", method, moviehash, source, adjusted, metrics)

    case verify_analysis_inputs(item, moviehash, source) do
      :ok -> persist_aligned(item, status, method, metadata)
      {:error, reason} -> result(item, :failed, method, %{reason: reason})
    end
  end

  defp persist_aligned(item, status, method, metadata) do
    case Manifest.put_sync(item.video_path, item.language, metadata) do
      :ok -> result(%{item | sync: metadata}, status, method, metadata)
      {:error, reason} -> result(item, :failed, method, %{reason: {:manifest, reason}})
    end
  end

  defp record_review(item, moviehash, method, source, metrics) do
    case verify_analysis_inputs(item, moviehash, source) do
      :ok ->
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

  defp apply_manual(item, moviehash, offset_ms, rate, expected_sha256) do
    item = prepare_replacement(item, moviehash)

    case item do
      %{auto_review_reason: reason} -> {:error, reason}
      _ -> apply_ready_manual(item, moviehash, offset_ms, rate, expected_sha256)
    end
  end

  defp apply_ready_manual(item, moviehash, offset_ms, rate, expected_sha256) do
    with {:ok, current} <- safe_read(item.sidecar_path),
         :ok <- verify_source_fingerprint(current, expected_sha256),
         {:ok, source} <- manual_source(item, current),
         {:ok, adjusted} <-
           Timing.retime(source, Path.extname(item.sidecar_path), offset_ms, rate) do
      status = if adjusted == current, do: :aligned, else: :corrected

      persist_manual(item, moviehash, source, current, adjusted, offset_ms, rate, status)
    end
  end

  defp manual_source(item, current) do
    backup = backup_path(item.sidecar_path)

    cond do
      not active_backup?(backup) ->
        {:ok, current}

      not immutable_backup_expected?(item.sync) ->
        {:error, :unexpected_backup}

      true ->
        with {:ok, source} <- safe_read(backup),
             :ok <- verify_backup_provenance(item.sync, source) do
          {:ok, source}
        end
    end
  end

  defp verify_backup_provenance(%{source_sha256: expected}, source) do
    if sha256(source) == expected, do: :ok, else: {:error, :backup_mismatch}
  end

  defp verify_backup_provenance(nil, _source), do: {:error, :unexpected_backup}

  defp persist_manual(item, moviehash, source, current, adjusted, offset_ms, rate, :aligned) do
    metadata =
      metadata("aligned", "manual", moviehash, source, adjusted, %{
        offset_ms: offset_ms,
        rate: rate
      })

    with :ok <- verify_current_content(item.sidecar_path, current),
         :ok <- verify_video_moviehash(item.video_path, moviehash) do
      case Manifest.put_sync(item.video_path, item.language, metadata) do
        :ok -> {:ok, :aligned, %{item | sync: metadata}}
        {:error, reason} -> {:error, {:manifest, reason}}
      end
    end
  end

  defp persist_manual(item, moviehash, source, current, adjusted, offset_ms, rate, :corrected) do
    metadata =
      metadata("aligned", "manual", moviehash, source, adjusted, %{
        offset_ms: offset_ms,
        rate: rate
      })

    case ensure_backup(item, source) do
      {:ok, backup_created?} ->
        begin_manual_correction(item, current, adjusted, backup_created?, metadata)

      {:error, _reason} = error ->
        error
    end
  end

  defp begin_manual_correction(item, current, adjusted, backup_created?, metadata) do
    pending =
      metadata
      |> Map.put(:status, "applying")
      |> Map.put(:expected_sha256, sha256(current))
      |> Map.put(:operation_id, operation_id())

    case verify_video_moviehash(item.video_path, metadata.moviehash) do
      :ok ->
        persist_pending_manual(item, pending, current, adjusted, backup_created?, metadata)

      {:error, reason} ->
        cleanup_unpublished_manual(item, backup_created?, reason)
    end
  end

  defp persist_pending_manual(item, pending, current, adjusted, backup_created?, metadata) do
    case Manifest.put_sync(item.video_path, item.language, pending) do
      :ok ->
        publish_manual_correction(
          item,
          current,
          adjusted,
          backup_created?,
          metadata,
          pending.operation_id
        )

      {:error, reason} ->
        cleanup_unpublished_manual(item, backup_created?, {:manifest, reason})
    end
  end

  defp publish_manual_correction(
         item,
         current,
         adjusted,
         backup_created?,
         metadata,
         operation_id
       ) do
    case atomic_write(item.sidecar_path, adjusted, current, operation_id) do
      :ok ->
        persist_manual_correction(item, current, adjusted, backup_created?, metadata)

      {:error, {:publication_committed, _detail} = reason} ->
        {:error, reason}

      {:error, reason} ->
        abort_prepared_manual(item, backup_created?, reason)
    end
  end

  defp abort_prepared_manual(item, backup_created?, reason) do
    case abort_prepared_correction(item, backup_created?) do
      :ok -> {:error, reason}
      {:error, cleanup_reason} -> {:error, {:apply_abort_failed, reason, cleanup_reason}}
    end
  end

  defp persist_manual_correction(item, current, adjusted, backup_created?, metadata) do
    case verify_video_moviehash(item.video_path, metadata.moviehash) do
      :ok ->
        persist_verified_manual_correction(
          item,
          current,
          adjusted,
          backup_created?,
          metadata
        )

      {:error, reason} ->
        rollback_manual(item, current, adjusted, backup_created?, reason)
    end
  end

  defp persist_verified_manual_correction(item, current, adjusted, backup_created?, metadata) do
    case Manifest.put_sync(item.video_path, item.language, metadata) do
      :ok ->
        {:ok, :corrected, %{item | sync: metadata}}

      {:error, reason} ->
        rollback_manual(item, current, adjusted, backup_created?, {:manifest, reason})
    end
  end

  defp rollback_manual(item, current, adjusted, backup_created?, failure_reason) do
    case rollback_prepared_correction(item, current, adjusted, backup_created?) do
      :ok ->
        {:error, failure_reason}

      {:error, rollback_reason} ->
        {:error, manual_rollback_failure(failure_reason, rollback_reason)}
    end
  end

  defp manual_rollback_failure({:manifest, reason}, rollback_reason),
    do: {:manifest_and_rollback_failed, reason, rollback_reason}

  defp manual_rollback_failure(reason, rollback_reason),
    do: {:correction_and_rollback_failed, reason, rollback_reason}

  defp reconcile_reset_cleanups(video_path, moviehash) do
    video_path
    |> Manifest.read()
    |> Map.fetch!(:tracks)
    |> Enum.reduce_while(:ok, fn entry, :ok ->
      reconcile_reset_entry(entry, video_path, moviehash)
    end)
  end

  defp reconcile_reset_entry(
         {_language, %{reset_cleanup_sync_invalid?: true}},
         _video_path,
         _moviehash
       ),
       do: {:halt, {:error, :invalid_reset_cleanup_journal}}

  defp reconcile_reset_entry(
         {language, %{file: file, reset_cleanup_sync: sync}},
         video_path,
         moviehash
       ) do
    if sync.moviehash == moviehash do
      item = %{
        video_path: video_path,
        sidecar_path: Path.join(Path.dirname(video_path), file),
        language: language,
        sync: sync,
        reset_cleanup_sync: sync
      }

      case complete_reset_cleanup(item, sync) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:reset_cleanup_failed, reason}}}
      end
    else
      {:halt, {:error, :reset_video_changed}}
    end
  end

  defp reconcile_reset_entry({_language, %{reset_cleanup_sync: _sync}}, _path, _hash),
    do: {:halt, {:error, :invalid_reset_cleanup_journal}}

  defp reconcile_reset_entry({_language, _track}, _video_path, _moviehash), do: {:cont, :ok}

  defp reset_item(%{sync: nil}), do: :ok

  defp reset_item(item) do
    with :ok <- Manifest.begin_reset_cleanup(item.video_path, item.language, item.sync),
         do: complete_reset_cleanup(%{item | reset_cleanup_sync: item.sync}, item.sync)
  end

  defp complete_reset_cleanup(item, sync) do
    backup = backup_path(item.sidecar_path)
    tombstone = Manifest.backup_tombstone(Manifest.read(item.video_path), item.language)

    with :ok <- ReplacementCleanup.reconcile_reversal(%{item | sync: sync}),
         :ok <- restore_for_reset(item, backup, sync),
         :ok <- retire_reset_backup(backup, sync, tombstone),
         do: Manifest.finish_reset_cleanup(item.video_path, item.language)
  end

  defp retire_reset_backup(backup, sync, tombstone) do
    cond do
      immutable_backup_expected?(sync) -> retire_owned_backup(backup, sync, tombstone)
      regular_file?(backup) -> {:error, :unexpected_backup}
      true -> :ok
    end
  end

  defp restore_for_reset(item, backup, sync) do
    with {:ok, current} <- safe_read(item.sidecar_path) do
      restore_current_for_reset(item, backup, sync, current, sha256(current))
    end
  end

  defp restore_current_for_reset(_item, _backup, %{source_sha256: source}, _current, source),
    do: :ok

  defp restore_current_for_reset(
         item,
         backup,
         %{source_sha256: source, applied_sha256: applied} = sync,
         current,
         applied
       )
       when source != applied do
    if regular_file?(backup) do
      with {:ok, original} <- safe_read(backup),
           :ok <- verify_backup_provenance(sync, original),
           do: atomic_write(item.sidecar_path, original, current)
    else
      {:error, :missing_backup}
    end
  end

  defp restore_current_for_reset(_item, _backup, _sync, _current, _hash),
    do: {:error, :concurrent_change}

  defp prepare_replacement(%{sync: nil} = item, _moviehash) do
    case file_sha256_result(item.sidecar_path) do
      {:ok, current_hash} when current_hash == item.managed_sha256 ->
        proof = %{source_sha256: item.managed_sha256}

        case discard_replacement(item.video_path, item.language, item.sidecar_path, proof) do
          :ok -> item
          {:error, _reason} -> block_cleanup(item)
        end

      {:ok, _other_hash} ->
        Map.put(item, :auto_review_reason, :externally_modified)

      {:error, _reason} ->
        block_cleanup(item)
    end
  end

  defp prepare_replacement(item, moviehash) do
    case ReplacementCleanup.reconcile_reversal(item) do
      :ok -> prepare_reconciled_replacement(item, moviehash)
      {:error, _reason} -> Map.put(item, :auto_review_reason, :apply_recovery_failed)
    end
  end

  defp prepare_reconciled_replacement(item, moviehash) do
    case file_sha256_result(item.sidecar_path) do
      {:ok, current_hash} -> prepare_replacement(item, moviehash, current_hash)
      {:error, _reason} -> block_cleanup(item)
    end
  end

  defp prepare_replacement(item, moviehash, current_hash) do
    cond do
      item.sync.status == "applying" and item.sync.moviehash == moviehash ->
        recover_pending_correction(item, current_hash)

      current_sync?(item, moviehash, current_hash) ->
        item

      current_hash == item.sync.source_sha256 ->
        clean_replacement(item, current_hash)

      item.sync.moviehash == moviehash ->
        Map.put(item, :auto_review_reason, :externally_modified)

      current_hash in [item.sync.source_sha256, item.sync.applied_sha256] ->
        clean_replacement(item, current_hash)

      true ->
        Map.put(item, :auto_review_reason, :externally_modified)
    end
  end

  defp recover_pending_correction(item, current_hash) do
    cond do
      current_hash == item.sync.applied_sha256 ->
        finalize_pending_correction(item)

      item.sync.method == "manual" and current_hash == item.sync.expected_sha256 ->
        resume_pending_manual(item)

      current_hash == item.sync.expected_sha256 ->
        retry_pending_correction(item)

      true ->
        Map.put(item, :auto_review_reason, :externally_modified)
    end
  end

  defp resume_pending_manual(item) do
    backup = backup_path(item.sidecar_path)

    with :ok <- verify_pending_backup(item),
         {:ok, current} <- safe_read(item.sidecar_path),
         true <- sha256(current) == item.sync.expected_sha256,
         {:ok, source} <- safe_read(backup),
         {:ok, adjusted} <-
           Timing.retime(
             source,
             Path.extname(item.sidecar_path),
             item.sync.offset_ms,
             item.sync.rate
           ),
         true <- sha256(adjusted) == item.sync.applied_sha256,
         :ok <- verify_video_moviehash(item.video_path, item.sync.moviehash),
         :ok <- atomic_write(item.sidecar_path, adjusted, current, item.sync.operation_id),
         :ok <- verify_video_moviehash(item.video_path, item.sync.moviehash) do
      finalize_pending_correction(item)
    else
      _ -> Map.put(item, :auto_review_reason, :apply_recovery_failed)
    end
  end

  defp finalize_pending_correction(item) do
    metadata =
      item.sync
      |> Map.delete(:expected_sha256)
      |> Map.delete(:operation_id)
      |> Map.put(:status, "aligned")

    with :ok <- verify_pending_backup(item),
         :ok <- cleanup_pending_workspace(item),
         :ok <- Manifest.put_sync(item.video_path, item.language, metadata) do
      %{item | sync: metadata}
    else
      {:error, _reason} -> Map.put(item, :auto_review_reason, :apply_recovery_failed)
    end
  end

  defp retry_pending_correction(item) do
    with :ok <- verify_pending_backup(item),
         :ok <-
           AtomicFile.recover(
             item.sidecar_path,
             item.sync.operation_id,
             item.sync.expected_sha256,
             item.sync.applied_sha256
           ),
         :ok <- verify_video_moviehash(item.video_path, item.sync.moviehash) do
      finalize_pending_correction(item)
    else
      {:error, _reason} -> Map.put(item, :auto_review_reason, :apply_recovery_failed)
    end
  end

  defp cleanup_pending_workspace(item) do
    AtomicFile.cleanup_pending(
      item.sidecar_path,
      item.sync.operation_id,
      item.sync.expected_sha256,
      item.sync.applied_sha256
    )
  end

  defp verify_pending_backup(item) do
    backup = backup_path(item.sidecar_path)

    if regular_file?(backup) do
      with {:ok, original} <- safe_read(backup),
           do: verify_backup_provenance(item.sync, original)
    else
      {:error, :missing_backup}
    end
  end

  defp clean_replacement(item, current_hash) do
    backup = backup_path(item.sidecar_path)

    with :ok <- restore_applied_original(item, backup, current_hash),
         :ok <- Manifest.begin_replacement_cleanup(item.video_path, item.language, item.sync) do
      finish_replacement_cleanup(%{item | sync: nil}, item.sync)
    else
      {:error, _reason} -> block_cleanup(item)
    end
  end

  defp finish_replacement_cleanup(item, sync) do
    with :ok <- discard_replacement(item.video_path, item.language, item.sidecar_path, sync),
         :ok <- Manifest.clear_replacement_cleanup(item.video_path, item.language) do
      item
    else
      {:error, _reason} -> block_cleanup(item)
    end
  end

  defp immutable_backup_expected?(%{source_sha256: source, applied_sha256: applied})
       when is_binary(source) and byte_size(source) == 64 and is_binary(applied) and
              byte_size(applied) == 64,
       do: source != applied

  defp immutable_backup_expected?(_sync), do: false

  defp retire_owned_backup(backup, sync, %{identity: identity})
       when is_list(identity) and length(identity) == 3 do
    expected_identity = List.to_tuple(identity)

    with_bound(backup, [:read, :raw, :binary], fn bound ->
      with true <- Filesystem.identity?(bound, expected_identity) || {:error, :unexpected_backup},
           {:ok, content} <- File.read(bound.path),
           :ok <- retire_backup_content(bound, content, sync) do
        verify_bound_source_identity(backup, bound.identity)
      end
    end)
  end

  defp retire_owned_backup(_backup, _sync, _tombstone),
    do: {:error, :missing_backup_tombstone}

  defp retire_backup_content(_bound, "", _sync), do: :ok

  defp retire_backup_content(bound, content, sync) do
    with :ok <- verify_backup_provenance(sync, content) do
      case fs().discard_bound(bound) do
        :ok -> verify_discarded_backup(bound)
        {:error, {:effect_committed, _operation, _reason}} -> verify_discarded_backup(bound)
        {:error, _reason} = error -> error
      end
    end
  end

  defp verify_discarded_backup(bound) do
    case File.read(bound.path) do
      {:ok, ""} -> :ok
      {:ok, _other} -> {:error, :backup_retirement_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp restore_applied_original(item, backup, current_hash) do
    cond do
      current_hash != item.sync.applied_sha256 ->
        :ok

      item.sync.source_sha256 == item.sync.applied_sha256 ->
        :ok

      not regular_file?(backup) ->
        {:error, :missing_backup}

      true ->
        with {:ok, current} <- safe_read(item.sidecar_path),
             {:ok, original} <- safe_read(backup),
             :ok <- verify_backup_provenance(item.sync, original),
             do: atomic_write(item.sidecar_path, original, current)
    end
  end

  defp block_cleanup(item), do: Map.put(item, :auto_review_reason, :replacement_cleanup_failed)

  defp current_sync?(item, moviehash) do
    case file_sha256_result(item.sidecar_path) do
      {:ok, current_hash} -> current_sync?(item, moviehash, current_hash)
      {:error, _reason} -> false
    end
  end

  defp current_sync?(item, moviehash, current_hash) do
    item.sync.moviehash == moviehash and
      current_hash == item.sync.applied_sha256
  end

  defp insignificant_correction?(metrics) do
    abs(Map.get(metrics, :offset_ms, 0)) <= 100 and
      abs(Map.get(metrics, :rate, 1.0) - 1.0) <= 0.0005
  end

  defp syncable_track?(track) do
    is_binary(Map.get(track, :file)) and is_binary(Map.get(track, :managed_sha256)) and
      not Map.get(track, :file_invalid?, false) and
      not Map.get(track, :managed_sha256_invalid?, false) and
      not Map.get(track, :sync_invalid?, false) and
      not Map.get(track, :replacement_cleanup_sync_invalid?, false) and
      not Map.get(track, :reset_cleanup_sync_invalid?, false) and
      not Map.get(track, :backup_tombstone_invalid?, false)
  end

  defp tracked_sidecar?(%{file: file}, _video_path, sidecar_path, _language),
    do: Path.basename(sidecar_path) == file

  defp tracked_sidecar?(_track, _video_path, _sidecar_path, _language), do: false

  defp verify_expected(_item, nil), do: :ok

  defp verify_expected(item, expected_sha256) when is_binary(expected_sha256) do
    if file_sha256(item.sidecar_path) == expected_sha256,
      do: :ok,
      else: {:error, :sidecar_changed}
  end

  defp verify_expected(_item, _expected_sha256), do: {:error, :invalid_fingerprint}

  defp verify_source_fingerprint(_source, nil), do: :ok

  defp verify_source_fingerprint(source, expected) when is_binary(expected) do
    if sha256(source) == expected, do: :ok, else: {:error, :sidecar_changed}
  end

  defp verify_source_fingerprint(_source, _expected), do: {:error, :invalid_fingerprint}

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
      managed_sha256: track.managed_sha256,
      sync: Map.get(track, :sync),
      review_reason: cleanup_review_reason(track, sidecar_path),
      reset_cleanup_sync: Map.get(track, :reset_cleanup_sync),
      backup_tombstone: Map.get(track, :backup_tombstone),
      label:
        "#{Path.basename(video_path)} · #{language} #{String.upcase(String.trim_leading(Path.extname(sidecar_path), "."))}"
    }
  end

  defp cleanup_review_reason(track, sidecar_path) do
    if is_nil(Map.get(track, :sync)) and active_backup?(backup_path(sidecar_path)),
      do: "replacement_cleanup_failed"
  end

  defp metadata(status, method, moviehash, source, applied, metrics) do
    %{
      version: 1,
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

  defp ensure_backup(item, expected_source) do
    backup = backup_path(item.sidecar_path)

    with {:ok, backup} <- safe_destination(backup) do
      create_or_verify_backup(backup, expected_source, item)
    end
  end

  defp create_or_verify_backup(backup, expected_source, item) do
    case fs().create_bound(backup, expected_source) do
      {:ok, bound} ->
        register_created_backup(item, bound)

      {:error, :eexist} ->
        cond do
          immutable_backup_expected?(item.sync) ->
            verify_existing_backup(backup, expected_source)

          Map.has_key?(item, :backup_tombstone) and is_map(item.backup_tombstone) ->
            reactivate_backup_container(backup, expected_source, item.backup_tombstone, item)

          true ->
            {:error, :unexpected_backup}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp register_created_backup(item, bound) do
    manifest_result =
      Manifest.put_backup_tombstone(item.video_path, item.language, bound.identity)

    close_result = fs().close_bound(bound)

    case {manifest_result, close_result} do
      {:ok, :ok} -> {:ok, true}
      {{:error, reason}, _close} -> {:error, {:backup_provenance_manifest_failed, reason}}
      {:ok, {:error, reason}} -> {:error, {:backup_descriptor_close_failed, reason}}
    end
  end

  defp reactivate_backup_container(backup, expected_source, %{identity: identity}, item)
       when is_list(identity) and length(identity) == 3 do
    expected_identity = List.to_tuple(identity)

    with_bound(backup, [:read, :raw, :binary], fn bound ->
      with true <- Filesystem.identity?(bound, expected_identity) || {:error, :unexpected_backup},
           {:ok, current} <- File.read(bound.path),
           :ok <- reactivate_backup_bytes(bound, current, expected_source),
           :ok <- Manifest.put_backup_tombstone(item.video_path, item.language, bound.identity),
           :ok <- verify_bound_source_identity(backup, bound.identity) do
        {:ok, true}
      end
    end)
  end

  defp reactivate_backup_container(_backup, _expected_source, _tombstone, _item),
    do: {:error, :invalid_backup_tombstone}

  defp reactivate_backup_bytes(_bound, expected_source, expected_source), do: :ok

  defp reactivate_backup_bytes(bound, "", expected_source),
    do: fs().write_bound(bound, expected_source)

  defp reactivate_backup_bytes(_bound, _current, _expected), do: {:error, :backup_mismatch}

  defp verify_bound_source_identity(path, expected_identity) do
    with_bound(path, [:read, :raw, :binary], fn rebound ->
      if rebound.identity == expected_identity, do: :ok, else: {:error, :concurrent_change}
    end)
  end

  defp verify_existing_backup(backup, expected_source) do
    case safe_read(backup) do
      {:ok, ^expected_source} -> {:ok, false}
      {:ok, _other} -> {:error, :backup_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp manifest_failure(item, previous, adjusted, backup_created?, method, reason) do
    case rollback_prepared_correction(item, previous, adjusted, backup_created?) do
      :ok ->
        result(item, :failed, method, %{reason: {:manifest, reason}})

      {:error, rollback_reason} ->
        result(item, :failed, method, %{
          reason: {:manifest_and_rollback_failed, reason, rollback_reason}
        })
    end
  end

  defp rollback_correction(item, previous, expected_applied) do
    with {:ok, current} <- safe_read(item.sidecar_path),
         true <- current == expected_applied,
         do: atomic_write(item.sidecar_path, previous, expected_applied),
         else: (
           false -> {:error, :concurrent_change}
           {:error, _reason} = error -> error
         )
  end

  defp rollback_prepared_correction(item, previous, expected_applied, backup_created?) do
    with :ok <- rollback_correction(item, previous, expected_applied),
         :ok <- restore_previous_sync(item),
         do: remove_new_backup(item, backup_created?)
  end

  defp cleanup_unpublished_correction(item, backup_created?, method, reason) do
    case cleanup_before_publication(item, backup_created?) do
      :ok ->
        result(item, :failed, method, %{reason: reason})

      {:error, cleanup_reason} ->
        result(item, :failed, method, %{
          reason: {:prepublication_cleanup_failed, reason, cleanup_reason}
        })
    end
  end

  defp cleanup_unpublished_manual(item, backup_created?, reason) do
    case cleanup_before_publication(item, backup_created?) do
      :ok ->
        {:error, reason}

      {:error, cleanup_reason} ->
        {:error, {:prepublication_cleanup_failed, reason, cleanup_reason}}
    end
  end

  defp cleanup_before_publication(item, backup_created?) do
    with :ok <- restore_previous_sync(item),
         do: remove_new_backup(item, backup_created?)
  end

  defp abort_prepared_correction(item, _backup_created?), do: restore_previous_sync(item)

  defp restore_previous_sync(%{sync: nil} = item),
    do: Manifest.clear_sync(item.video_path, item.language)

  defp restore_previous_sync(item),
    do: Manifest.put_sync(item.video_path, item.language, item.sync)

  defp remove_new_backup(item, true) do
    backup = backup_path(item.sidecar_path)
    tombstone = Manifest.backup_tombstone(Manifest.read(item.video_path), item.language)

    with {:ok, current} <- safe_read(item.sidecar_path),
         do: retire_owned_backup(backup, %{source_sha256: sha256(current)}, tombstone)
  end

  defp remove_new_backup(_item, false), do: :ok

  defp atomic_write(target, content, expected_current),
    do: AtomicFile.write(target, content, expected_current)

  defp atomic_write(target, content, expected_current, operation_id),
    do: AtomicFile.write(target, content, expected_current, operation_id)

  defp operation_id,
    do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

  defp safe_read(path) do
    with {:ok, path} <- safe_source(path), do: fs().read(path)
  end

  defp verify_current_content(path, expected) do
    case safe_read(path) do
      {:ok, ^expected} -> :ok
      {:ok, _changed} -> {:error, :concurrent_change}
      {:error, _reason} = error -> error
    end
  end

  defp regular_file?(path) do
    with {:ok, path} <- safe_source(path),
         {:ok, %File.Stat{type: :regular}} <- fs().lstat(path),
         do: true,
         else: (_ -> false)
  end

  defp active_backup?(path) do
    case safe_destination(path) do
      {:ok, path} ->
        case fs().lstat(path) do
          {:ok, %File.Stat{type: :regular, size: 0}} -> false
          {:error, :enoent} -> false
          _other -> true
        end

      {:error, _reason} ->
        true
    end
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

  defp current_moviehash(video_path) do
    case Moviehash.of_file(video_path) do
      {:ok, _moviehash} = result -> result
      {:error, _reason} = error -> error
      :too_small -> {:error, :too_small}
      other -> {:error, {:moviehash_unexpected, other}}
    end
  end

  defp verify_analysis_inputs(item, moviehash, source) do
    with :ok <- verify_current_content(item.sidecar_path, source),
         do: verify_video_moviehash(item.video_path, moviehash)
  end

  defp verify_video_moviehash(video_path, expected) do
    case current_moviehash(video_path) do
      {:ok, ^expected} -> :ok
      {:ok, _other} -> {:error, :video_changed}
      {:error, _reason} -> {:error, :moviehash_unavailable}
    end
  end

  defp file_sha256(path) do
    case file_sha256_result(path) do
      {:ok, hash} -> hash
      {:error, _reason} -> nil
    end
  end

  defp file_sha256_result(path) do
    case safe_read(path) do
      {:ok, content} -> {:ok, sha256(content)}
      {:error, _reason} = error -> error
    end
  end

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  defp reason(nil), do: nil
  defp reason(value) when is_atom(value), do: Atom.to_string(value)
  defp reason(value) when is_binary(value), do: value
  defp reason(value), do: inspect(value)

  defp engine_sync(reference, input, output, reference_extension, input_extension) do
    module = engine()

    if function_exported?(module, :sync, 5) do
      module.sync(reference, input, output, reference_extension, input_extension)
    else
      module.sync(reference, input, output)
    end
  end

  defp engine,
    do: Application.get_env(:cinder, :subtitle_sync_engine, Cinder.Subtitles.Sync.Ffsubsync)

  defp media_info, do: Application.get_env(:cinder, :media_info)
  defp fs, do: Application.fetch_env!(:cinder, :filesystem)
  defp path_policy, do: Application.get_env(:cinder, :path_policy, PathPolicy)
end
