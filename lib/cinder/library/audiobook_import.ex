defmodule Cinder.Library.AudiobookImport do
  @moduledoc """
  Publishes a downloaded audiobook's ordered track set into the library and records the
  resulting `book_files` rows — the `Cinder.Library.BookImport` sibling, and the one place the
  roadmap's "a multi-track audiobook is imported atomically as one target" and "no mixed-book
  imports" questions are actually answered.

  ## Order of operations

  1. Resolve the payload to an ordered list of accepted, validated tracks
     (`Cinder.Library.AudiobookSources.resolve/1`) — refuse otherwise.
  2. **Stage every track, accumulating rollback tokens as it goes.** On the FIRST staging
     failure, every rollback token accumulated so far is rolled back before returning
     `{:error, reason}` — for a fresh import this means zero bytes land under the target's
     folder; for a replace, each already-swapped track's rollback restores that track's own
     original file from its own backup path (`Cinder.Library.StageEngine.stage_book_place/4`'s
     `:replace` path), so a partial failure never leaves a half-landed mixed set.
  3. Record every `book_files` row and arm the target `:available`, in ONE transaction
     (`Cinder.Books.Files.record_import_set/3`) — the multi-file generalization of
     `Cinder.Books.Files.record_import/3`.
  4. Only if that DB write commits, commit every stage. A committed catalog write with an
     unfinished stage commit is logged and the import stands (`reconcile_stages/0` retries the
     journal on its own schedule) — never re-imported, per each single-file import's own
     "commit already logged, not retried" precedent, generalized to N tokens.

  Nothing about two-phase commit is reimplemented here; every step reuses
  `Cinder.Library.StageEngine`, `Cinder.Books.Files`, and `Cinder.Library.ImportStage` exactly as
  `BookImport` does.
  """
  require Logger

  alias Cinder.Books
  alias Cinder.Books.{BookGrab, BookTarget}
  alias Cinder.Download
  alias Cinder.Library
  alias Cinder.Library.{AudiobookNaming, AudiobookSources, StageEngine}
  alias Cinder.Settings

  @doc """
  Imports `grab`'s completed multi-track payload for its audiobook target.

  Returns `{:ok, book_files}` (one row per track) or, with `opts[:replace]` superseding a genuine
  prior set, `{:ok, book_files, superseded_paths}` — mirroring `BookImport.import_grab/2`'s own
  return shape, generalized from one file to a list. See its docs for the shared `opts[:replace]`
  contract; `record/3` below forwards it to `Cinder.Books.Files.record_import_set/3` unchanged.
  """
  @spec import_grab(BookGrab.t(), keyword()) ::
          {:ok, [struct()]} | {:ok, [struct()], [String.t()]} | {:error, term()}
  def import_grab(grab, opts \\ [])

  def import_grab(%BookGrab{content_path: path}, _opts) when path in [nil, ""],
    do: {:error, :missing_content_path}

  def import_grab(%BookGrab{book_target: %BookTarget{} = target} = grab, opts) do
    replace? = Keyword.get(opts, :replace, false)

    with {:ok, tracks} <- AudiobookSources.resolve(grab.content_path),
         {:ok, root} <- library_root(target),
         {:ok, staged} <- stage_all(tracks, target, root, replace?) do
      record(grab, target, staged, opts)
    end
  end

  def import_grab(%BookGrab{}, _opts), do: {:error, :book_target_not_loaded}

  defp library_root(%BookTarget{media_kind: media_kind} = target),
    do: Settings.library_root(media_kind, target)

  # --- staging: accumulate rollback tokens, roll everything back on the first failure ---

  defp stage_all(tracks, target, root, replace?) do
    total = length(tracks)
    multi_disc? = tracks |> Enum.map(& &1.order_disc) |> Enum.uniq() |> length() > 1

    tracks
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {track, index}, {:ok, staged_so_far} ->
      meta = %{index: index, total: total, disc: track.order_disc, multi_disc?: multi_disc?}
      dest = AudiobookNaming.track_dest(target.work, track.format, root, meta)

      case stage_track(track, dest, root, replace?) do
        {:ok, staged} -> {:cont, {:ok, [staged | staged_so_far]}}
        {:error, reason} -> {:halt, {:error, reason, staged_so_far}}
      end
    end)
    |> finish_staging()
  end

  defp stage_track(track, dest, root, replace?) do
    with {:ok, _vetted_dir} <- AudiobookSources.safe_destination(Path.dirname(dest), root),
         :ok <- fs().mkdir_p(Path.dirname(dest)),
         {:ok, rollback, placed?} <-
           StageEngine.stage_book_place(track.path, dest, root,
             extensions: AudiobookSources.accepted_extensions(),
             replace: replace?
           ),
         {:ok, size} <- recorded_size(placed?, track.path, dest) do
      {:ok, %{track: track, dest: dest, rollback: rollback, size: size}}
    end
  end

  # Same reasoning as `BookImport`'s own `recorded_size/3`: `placed?: false` means the destination
  # already held a file and nothing landed, so the recorded size describes what is ACTUALLY there.
  defp recorded_size(true, source, _dest) do
    case fs().lstat(source) do
      {:ok, %{size: size}} -> {:ok, size}
      {:error, reason} -> {:error, reason}
    end
  end

  defp recorded_size(false, _source, dest) do
    case fs().lstat(dest) do
      {:ok, %{size: size}} -> {:ok, size}
      {:error, reason} -> {:error, reason}
    end
  end

  defp finish_staging({:ok, staged}), do: {:ok, Enum.reverse(staged)}

  defp finish_staging({:error, reason, staged_so_far}) do
    Enum.each(staged_so_far, &rollback(&1.rollback, reason))
    {:error, reason}
  end

  # --- record phase ---

  defp record(grab, target, staged, opts) do
    replace? = Keyword.get(opts, :replace, false)
    stage_ids = Library.stage_ids(Enum.map(staged, &%{rollback: &1.rollback}))

    attrs_list =
      Enum.map(staged, fn %{track: track, dest: dest, size: size} ->
        %{
          path: dest,
          format: track.format,
          size: size,
          track_number: track.track_number,
          disc_number: track.disc_number,
          duration_seconds: track.duration_seconds,
          chapter_count: track.chapter_count
        }
      end)

    case Books.Files.record_import_set(target, attrs_list,
           import_stage_ids: stage_ids,
           replace: replace?
         ) do
      {:ok, files} -> commit(grab, files, staged, [])
      {:ok, files, superseded_paths} -> commit(grab, files, staged, superseded_paths)
      {:error, reason} -> abort(reason, staged)
    end
  end

  defp abort(reason, staged) do
    Enum.each(staged, &rollback(&1.rollback, reason))
    {:error, reason}
  end

  # Best-effort per token, logged and never retried — the same "commit already logged, not
  # retried" precedent `BookImport.commit/4` applies to one file, generalized to N: the catalog
  # write already committed, so reporting an error here would re-import files the catalog already
  # claims.
  defp commit(grab, files, staged, superseded_paths) do
    Enum.each(staged, fn %{rollback: rollback, dest: dest} ->
      case StageEngine.commit(rollback) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "audiobook file #{dest} imported but its stage did not commit: #{inspect(reason)}"
          )
      end
    end)

    finish(grab, files, superseded_paths)
  end

  # Post-commit, best-effort. ORDER MATTERS: delete the grab first, then honour `move_on_import` —
  # the same crash-window reasoning `BookImport.finish/3` documents.
  defp finish(grab, files, superseded_paths) do
    Books.Grabs.delete(grab)
    Download.remove_after_import(grab.download_protocol, grab.download_id, grab.content_path)
    if superseded_paths == [], do: {:ok, files}, else: {:ok, files, superseded_paths}
  end

  defp rollback(rollback, reason) do
    case StageEngine.rollback(rollback) do
      :ok ->
        :ok

      {:error, rollback_error} ->
        Logger.error(
          "audiobook import rollback failed after #{inspect(reason)}: #{inspect(rollback_error)}"
        )

        :ok
    end
  end

  defp fs, do: Application.fetch_env!(:cinder, :filesystem)
end
