defmodule Cinder.Library.AudiobookImport do
  @moduledoc """
  Publishes a downloaded audiobook's ordered track set into the library and records the
  resulting `book_files` rows — the `Cinder.Library.EbookImport` sibling, and the one place the
  roadmap's "a multi-track audiobook is imported atomically as one target" and "no mixed-book
  imports" questions are actually answered.

  ## Order of operations

  1. Resolve the payload to an ordered list of accepted, validated tracks
     (`Cinder.Library.AudiobookSources.resolve/1`) — refuse otherwise.
  2. **Stage every track into one staged import** (`Cinder.Library.StagedImport`). On the FIRST
     staging failure the whole set is rolled back before returning `{:error, reason}` — for a
     fresh import this means zero bytes land under the target's folder; for a replace, each
     already-swapped track restores its own original file from its own backup path, so a
     partial failure never leaves a half-landed mixed set.
  3. Record every `book_files` row and arm the target `:available`, in ONE transaction
     (`Cinder.Books.Files.record_import_set/3`) — the multi-file generalization of
     `Cinder.Books.Files.record_import/3` — which marks every track's stage committed.
  4. The staged import then commits every track, or rolls them all back when the write lost. A
     committed catalog write with an unfinished stage commit is logged and the import stands
     (`StagedImport.reconcile/0` retries the journal on its own schedule) — never re-imported.

  Nothing about two-phase commit is reimplemented here; every step reuses `StagedImport` and
  `Cinder.Books.Files` exactly as `EbookImport` does.
  """
  alias Cinder.Books
  alias Cinder.Books.{BookGrab, BookTarget}
  alias Cinder.Download
  alias Cinder.Library.{AudiobookNaming, AudiobookSources, StagedImport}
  alias Cinder.Settings

  @doc """
  Imports `grab`'s completed multi-track payload for its audiobook target.

  Returns `{:ok, book_files}` (one row per track) or, with `opts[:replace]` superseding a genuine
  prior set, `{:ok, book_files, superseded_paths}` — mirroring `EbookImport.import_grab/2`'s own
  return shape, generalized from one file to a list. See its docs for the shared `opts[:replace]`
  contract; `record/4` below forwards it to `Cinder.Books.Files.record_import_set/3` unchanged.
  """
  @spec import_grab(BookGrab.t(), keyword()) ::
          {:ok, [struct()]} | {:ok, [struct()], [String.t()]} | {:error, term()}
  def import_grab(grab, opts \\ [])

  def import_grab(%BookGrab{content_path: path}, _opts) when path in [nil, ""],
    do: {:error, :no_content_path}

  def import_grab(%BookGrab{book_target: %BookTarget{} = target} = grab, opts) do
    replace? = Keyword.get(opts, :replace, false)

    with {:ok, tracks} <- AudiobookSources.resolve(grab.content_path),
         {:ok, root} <- library_root(target),
         {:ok, staged} <- stage_all(tracks, target, root, replace?) do
      record(staged, grab, target, replace?)
    end
  end

  def import_grab(%BookGrab{}, _opts), do: {:error, :book_target_not_loaded}

  defp library_root(%BookTarget{media_kind: media_kind} = target),
    do: Settings.library_root(media_kind, target)

  # --- staging: one staged import for the whole set, rolled back on the first failure ---

  defp stage_all(tracks, target, root, replace?) do
    total = length(tracks)
    multi_disc? = tracks |> Enum.map(& &1.order_disc) |> Enum.uniq() |> length() > 1

    tracks
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, StagedImport.new(), []}, fn {track, index}, {:ok, staged, attrs} ->
      meta = %{index: index, total: total, disc: track.order_disc, multi_disc?: multi_disc?}
      dest = AudiobookNaming.track_dest(target.work, track.format, root, meta)

      case stage_track(staged, track, dest, root, replace?) do
        {:ok, staged, track_attrs} ->
          {:cont, {:ok, staged, [track_attrs | attrs]}}

        {:error, reason, staged} ->
          StagedImport.rollback(staged)
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, staged, attrs} -> {:ok, StagedImport.put_record(staged, Enum.reverse(attrs))}
      {:error, _reason} = error -> error
    end
  end

  # `changed?` carries this track's actual staging outcome through to
  # `Files.record_import_set/3` — see that call's own `insert_all_or_existing/3` comment for why a
  # same-inode replay (nothing placed) must never refresh a row's metadata even when `replace?` is
  # true, regardless of what this tick's own probe attempt returned.
  #
  # A failure returns the handle as it stands, including this track when it was already placed,
  # so the caller's rollback covers it too.
  defp stage_track(staged, track, dest, root, replace?) do
    with {:ok, _vetted_dir} <- AudiobookSources.safe_destination(Path.dirname(dest), root),
         :ok <- fs().mkdir_p(Path.dirname(dest)),
         {:ok, staged, outcome} <-
           StagedImport.place(staged, track.path, dest, root,
             on_collision: if(replace?, do: :replace, else: :keep),
             extensions: AudiobookSources.accepted_extensions()
           ) do
      placed? = outcome in [:placed, :replaced]

      case recorded_size(placed?, track.path, dest) do
        {:ok, size} -> {:ok, staged, track_attrs(track, dest, size, placed?)}
        {:error, reason} -> {:error, reason, staged}
      end
    else
      {:error, reason} -> {:error, reason, staged}
    end
  end

  defp track_attrs(track, dest, size, placed?) do
    %{
      path: dest,
      format: track.format,
      size: size,
      track_number: track.track_number,
      disc_number: track.disc_number,
      duration_seconds: track.duration_seconds,
      chapter_count: track.chapter_count,
      changed?: placed?
    }
  end

  # Same reasoning as `EbookImport`'s own `recorded_size/3`: when nothing was placed, the
  # destination already held a file, so the recorded size describes what is ACTUALLY there.
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

  # --- record phase ---

  # `record_import_set/3` marks every track's stage committed in the one transaction that records
  # them, so a losing write commits none of them and the whole set rolls back.
  defp record(staged, grab, target, replace?) do
    write = &Books.Files.record_import_set(target, &1, import_stage_ids: &2, replace: replace?)

    case StagedImport.commit(staged, write) do
      {:ok, files} ->
        Download.release_imported_book_grab(grab)
        {:ok, files}

      {:ok, files, []} ->
        Download.release_imported_book_grab(grab)
        {:ok, files}

      {:ok, files, superseded_paths} ->
        Download.release_imported_book_grab(grab)
        {:ok, files, superseded_paths}

      {:error, _reason} = error ->
        error
    end
  end

  defp fs, do: Application.fetch_env!(:cinder, :filesystem)
end
