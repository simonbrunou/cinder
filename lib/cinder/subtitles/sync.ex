defmodule Cinder.Subtitles.Sync do
  @moduledoc "Synchronizes Cinder-managed adjacent subtitle sidecars."
  require Logger

  alias Cinder.Library.Sidecars
  alias Cinder.Subtitles.{Manifest, Moviehash, SafeFile, SidecarTransaction}
  alias Cinder.Subtitles.Sync.{EngineWorkspace, Output, Record, Reference, Scope, Timing}

  @managed_origins ~w(opensubtitles_hash opensubtitles_id own_track)
  # Bumped whenever the alignment an automatic pass would produce changes, so already-"aligned"
  # sidecars are restored from their originals and re-analyzed instead of being trusted forever.
  # 3: piecewise alignment, a subtitle reference the engine reads as subtitles, and framerate
  # corrections beyond ±5% — v2 results left structural and NTSC-ratio drift in place.
  # 4: piecewise alignment keeps cues in order — v3 could move a run of cues onto speech other
  # cues already covered, showing two lines at once and then nothing.
  # 5: song lyrics are not speech when the reference is a subtitle track — an SDH reference
  # read a sung theme as continuous dialogue and pulled a cold open onto it.
  # 6: the Netflix timing rules (2-frame gaps, chaining, 20-frame minimum) on every result.
  @sync_version 6
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

  @doc "The single unit owning `video_path`, resolved without loading the whole catalog."
  @spec unit_for_video_path(String.t(), :movies | :tv) :: map() | nil
  defdelegate unit_for_video_path(video_path, kind), to: Scope

  @doc """
  Runs automatic analysis for every managed sidecar belonging to a video. `shot_changes: :detect`
  finds the video's cuts when none are cached (minutes of CPU); the default `:cached` only reads
  them, and redoes a result once cuts it did not have become known.
  """
  @spec analyze_video(String.t(), keyword()) :: [map()]
  def analyze_video(video_path, opts \\ []) do
    :global.trans({{Cinder.Subtitles, video_path}, self()}, fn ->
      do_analyze_video(video_path, opts)
    end)
  end

  defp do_analyze_video(video_path, opts) when is_list(opts) do
    case discover(video_path) do
      [] ->
        []

      _items ->
        analyze_managed_video(video_path, opts)
    end
  end

  defp analyze_managed_video(video_path, opts) do
    case current_moviehash(video_path) do
      {:ok, moviehash} ->
        case SidecarTransaction.reconcile(video_path, moviehash) do
          :ok -> do_analyze_video(video_path, moviehash, opts)
          {:error, reason} -> failed_reconciliation(video_path, reason)
        end

      {:error, _reason} ->
        moviehash_unavailable(video_path)
    end
  end

  defp failed_reconciliation(video_path, reason),
    do: Enum.map(discover(video_path), &result(&1, :failed, nil, %{reason: reason}))

  defp do_analyze_video(video_path, moviehash, opts) do
    discovered = discover(video_path)
    shots = Output.shot_changes(video_path, moviehash, discovered, opts)
    items = Enum.map(discovered, &prepare_item(&1, moviehash, shots))

    needed? = Enum.any?(items, &analysis_needed?/1)
    aligning? = Enum.any?(items, &(analysis_needed?(&1) and not native?(&1, moviehash)))
    resolver = Reference.resolver(if(aligning?, do: media_info()), video_path)
    frame_rate = if needed?, do: Output.frame_rate(media_info(), video_path)

    Enum.map(items, fn item ->
      {reference, reference_source} =
        if native?(item, moviehash), do: {nil, nil}, else: resolver.(item.language)

      analyze_item(Map.put(item, :frame_rate, frame_rate), moviehash, reference, reference_source)
    end)
  end

  defp native?(item, moviehash),
    do: item.origin == "own_track" and item.source_moviehash == moviehash

  defp analysis_needed?(%{auto_review_reason: _reason}), do: false
  defp analysis_needed?(%{sync: %{status: status}}), do: status not in ["aligned", "review"]
  defp analysis_needed?(_item), do: true

  defp prepare_item(item, hash, shots) do
    item
    |> reset_obsolete(hash, shots)
    |> prepare_replacement(hash)
    |> Map.put(:shot_changes, shots)
  end

  defp reset_obsolete(%{sync: %{version: @sync_version} = sync} = item, _moviehash, shots)
       when is_nil(shots) or is_map_key(sync, :shot_changes),
       do: item

  defp reset_obsolete(%{sync: %{method: method}} = item, moviehash, _shots)
       when method in ~w(audio embedded native) do
    with :ok <- SidecarTransaction.restore_original(item, moviehash),
         {:ok, fresh} <- resolve(item.video_path, item.id),
         do: fresh,
         else: (_ -> Map.put(item, :auto_review_reason, :obsolete_automatic_reset_failed))
  end

  defp reset_obsolete(item, _moviehash, _shots), do: item

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

  @doc """
  Applies a manual correction, re-validated against `scope` after the filesystem/manifest work
  completes. Does not hold SQLite's write lock across that I/O (#453) — see `with_scoped_item/3`.
  """
  @spec manual_in_scope(term(), String.t(), integer(), number(), String.t()) ::
          {:ok, :aligned | :corrected, item()} | {:error, term()}
  def manual_in_scope(scope, id, offset_ms, rate, expected_sha256) do
    with_scoped_item(scope, id, fn item ->
      manual(item, offset_ms, rate, expected_sha256)
    end)
  end

  @doc """
  Resets a subtitle, re-validated against `scope` after the filesystem/manifest work completes
  (see `with_scoped_item/3`).
  """
  @spec reset_in_scope(term(), String.t()) :: :ok | {:error, term()}
  def reset_in_scope(scope, id), do: with_scoped_item(scope, id, &reset/1)

  # `callback` (`manual/4`/`reset/1`) is pure filesystem/manifest I/O — no DB write at all — so
  # wrapping it in `Repo.transaction(mode: :immediate)` bought no atomicity; it only reserved
  # SQLite's single, DATABASE-WIDE write lock for the whole operation. On a slow or
  # network-mounted library root that queued every *unrelated* writer in the app (other titles'
  # poller ticks included) behind however long the manifest read, sidecar scan, one-or-two
  # `Moviehash.of_file/1` reads, and manifest write took (#453) — for zero atomicity benefit,
  # since nothing here was ever written to the DB.
  #
  # What that reservation *did* incidentally buy, and what this still preserves without the lock:
  # the operator is never told "success" for an item whose catalog scope moved out from under the
  # operation (e.g. an upgrade import reassigning `file_path` mid-flight). `items(scope)` is
  # resolved once before `callback` runs and once more after a successful callback; if the item no
  # longer resolves within `scope`, the call reports `{:error, :stale_scope}` instead of a false
  # success, mirroring the codebase's other re-validate-on-a-losing-race guards. This is a report,
  # not a block: a concurrent catalog write is no longer serialized behind this operation, only
  # detected if it invalidated the scope. Two things already cover the rest of what the lock's
  # ordering incidentally provided: `manual/4` re-verifies the video's own bytes (moviehash) and
  # the sidecar's (sha256) mid-flight, independent of any DB lock; `:global.trans/2` (keyed on
  # `video_path`, still held around `manual/4`'s and `reset/1`'s own bodies) already serializes
  # concurrent subtitle-sync calls for the same video. Neither depended on the write lock.
  defp with_scoped_item(scope, id, callback) do
    case find_scoped_item(scope, id) do
      nil -> {:error, :unknown_item}
      item -> revalidate_scope(scope, id, callback.(item))
    end
  end

  defp revalidate_scope(_scope, _id, {:error, _reason} = error), do: error

  defp revalidate_scope(scope, id, success) do
    if find_scoped_item(scope, id), do: success, else: {:error, :stale_scope}
  end

  defp find_scoped_item(scope, id), do: Enum.find(items(scope), &(&1.id == id))

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
        SidecarTransaction.restore_original(item, moviehash)
      else
        {:error, :too_small} -> {:error, :moviehash_unavailable}
        {:error, _reason} = error -> error
      end
    end)
  end

  def reset(_item), do: {:error, :unknown_item}

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

  # The video's own track is already timed to this cut: it gets the timing rules, no alignment. One
  # extracted from a file since replaced at the same path is aligned like any other sidecar.
  defp analyze_item(%{origin: "own_track", source_moviehash: moviehash} = item, moviehash, _, _) do
    case SafeFile.safe_source(item.sidecar_path) do
      {:ok, input_path} ->
        input_path
        |> with_bound([:read, :raw, :binary], &apply_native(item, moviehash, &1))
        |> normalize_engine_result(item, "native")

      {:error, reason} ->
        result(item, :failed, "native", %{reason: reason})
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

  defp apply_native(item, moviehash, input) do
    with {:ok, source} <- File.read(input.path) do
      metrics = %{offset_ms: 0, rate: 1.0, shot_changes: is_list(Map.get(item, :shot_changes))}
      apply_engine_output(item, moviehash, "native", source, source, metrics)
    end
  end

  defp run_engine(item, moviehash, method, {:content, content} = reference)
       when is_binary(content) do
    case SafeFile.safe_source(item.sidecar_path) do
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
    with {:ok, reference_path} <- SafeFile.safe_source(reference_path),
         {:ok, input_path} <- SafeFile.safe_source(item.sidecar_path) do
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
    # An embedded reference is always extracted as SRT (`-c:s srt`); only the audio method hands
    # the engine the video container itself. Both paths reach the engine as an extension-less
    # descriptor path, so the format has to travel separately — and a subtitle reference the
    # engine can read as subtitles is what lets it infer a framerate ratio from durations.
    reference_extension = if method == "audio", do: Path.extname(item.video_path), else: ".srt"
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
    case SafeFile.fs().open_bound(path, modes) do
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

    close_result = SafeFile.fs().close_bound(bound)
    finish_bound_operation(operation, close_result)
  end

  defp finish_bound_operation({:returned, result}, :ok), do: result

  defp finish_bound_operation({:returned, %{status: _status} = result}, {:error, reason}) do
    Logger.warning(
      "descriptor close failed after completed subtitle analysis: #{inspect(reason)}"
    )

    result
  end

  defp finish_bound_operation({:returned, _result}, {:error, reason}),
    do: {:error, {:descriptor_close_failed, reason}}

  defp finish_bound_operation({:raised, kind, reason, stacktrace}, _close_result),
    do: :erlang.raise(kind, reason, stacktrace)

  defp handle_engine_result(item, moviehash, method, source, engine_result, output_result) do
    shots = %{shot_changes: not is_nil(Map.get(item, :shot_changes))}

    case engine_result do
      {:ok, metrics} ->
        case output_result do
          {:ok, adjusted} ->
            apply_engine_output(
              item,
              moviehash,
              method,
              source,
              adjusted,
              Map.merge(metrics, shots)
            )

          {:error, reason} ->
            result(item, :failed, method, %{reason: reason})
        end

      {:review, metrics} ->
        record_review(item, moviehash, method, source, Map.merge(metrics, shots))

      {:error, _reason} ->
        record_review(item, moviehash, method, source, Map.put(shots, :reason, :engine_failed))
    end
  end

  defp apply_engine_output(item, moviehash, method, source, adjusted, metrics) do
    extension = Path.extname(item.sidecar_path)

    with :ok <- Timing.validate(adjusted, extension),
         opts = [
           frame_rate: Map.get(item, :frame_rate),
           shot_changes: Map.get(item, :shot_changes)
         ],
         {:ok, adjusted} <- Output.automatic(source, adjusted, metrics, extension, opts) do
      record = metadata("aligned", method, moviehash, source, adjusted, metrics)
      publish(item, method, source, adjusted, record)
    else
      {:error, :invalid_subtitle} ->
        result(item, :failed, method, %{reason: :invalid_engine_output})

      {:error, reason} ->
        result(item, :failed, method, %{reason: reason})
    end
  end

  defp record_review(item, moviehash, method, source, metrics) do
    record = metadata("review", method, moviehash, source, source, metrics)
    publish(item, method, source, source, record)
  end

  defp publish(item, method, source, content, record) do
    case SidecarTransaction.publish(item, source, content, record) do
      {:ok, status, item} -> result(item, status, method, record)
      {:error, reason} -> result(item, :failed, method, %{reason: reason})
    end
  end

  defp record_blocked_review(%{sync: nil} = item, reason) do
    result(item, :review, "replacement", %{reason: Atom.to_string(reason)})
  end

  defp record_blocked_review(item, reason) do
    case SidecarTransaction.hold_for_review(item, reason) do
      {:ok, item} ->
        result(item, :review, item.sync.method, item.sync)

      {:error, manifest_error} ->
        result(item, :failed, item.sync.method, %{reason: manifest_error})
    end
  end

  defp apply_manual(item, moviehash, offset_ms, rate, expected_sha256) do
    case SidecarTransaction.recover(item, moviehash) do
      {:ok, item} -> apply_ready_manual(item, moviehash, offset_ms, rate, expected_sha256)
      {:review, reason, _item} -> {:error, reason}
    end
  end

  defp apply_ready_manual(item, moviehash, offset_ms, rate, expected_sha256) do
    extension = Path.extname(item.sidecar_path)

    with {:ok, current} <- SafeFile.safe_read(item.sidecar_path),
         :ok <- verify_source_fingerprint(current, expected_sha256),
         {:ok, source} <- SidecarTransaction.original(item, current),
         {:ok, adjusted} <- Timing.retime(source, extension, offset_ms, rate) do
      record =
        metadata("aligned", "manual", moviehash, source, adjusted, %{
          offset_ms: offset_ms,
          rate: rate
        })

      SidecarTransaction.publish(item, current, adjusted, record)
    end
  end

  defp prepare_replacement(item, moviehash) do
    case SidecarTransaction.recover(item, moviehash) do
      {:ok, item} -> item
      {:review, reason, item} -> Map.put(item, :auto_review_reason, reason)
    end
  end

  defp current_sync?(item, moviehash) do
    case SafeFile.file_sha256(item.sidecar_path) do
      {:ok, current_hash} -> current_sync?(item, moviehash, current_hash)
      {:error, _reason} -> false
    end
  end

  defp current_sync?(item, moviehash, current_hash) do
    item.sync.moviehash == moviehash and
      current_hash == item.sync.applied_sha256
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
    if SafeFile.sha256(source) == expected, do: :ok, else: {:error, :sidecar_changed}
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
      source_moviehash: Map.get(track, :source_moviehash),
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
    if is_nil(Map.get(track, :sync)) and SidecarTransaction.stranded_backup?(sidecar_path),
      do: "replacement_cleanup_failed"
  end

  defp metadata(status, method, moviehash, source, applied, metrics),
    do: Record.metadata(@sync_version, status, method, moviehash, source, applied, metrics)

  defp result(item, status, method, metadata), do: Record.result(item, status, method, metadata)

  defp current_moviehash(video_path) do
    case Moviehash.of_file(video_path) do
      {:ok, _moviehash} = result -> result
      {:error, _reason} = error -> error
      :too_small -> {:error, :too_small}
      other -> {:error, {:moviehash_unexpected, other}}
    end
  end

  defp file_sha256(path) do
    case SafeFile.file_sha256(path) do
      {:ok, hash} -> hash
      {:error, _reason} -> nil
    end
  end

  # `function_exported?/3` answers for *loaded* modules only, and code loading is lazy: probing
  # before the engine module has ever been called reports no `sync/5` and silently drops the
  # format arguments the extension-less descriptor paths cannot carry.
  defp engine_sync(reference, input, output, reference_extension, input_extension) do
    module = engine()

    if Code.ensure_loaded?(module) and function_exported?(module, :sync, 5) do
      module.sync(reference, input, output, reference_extension, input_extension)
    else
      module.sync(reference, input, output)
    end
  end

  defp engine,
    do: Application.get_env(:cinder, :subtitle_sync_engine, Cinder.Subtitles.Sync.Ffsubsync)

  defp media_info, do: Application.get_env(:cinder, :media_info)
end
