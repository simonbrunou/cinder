defmodule Cinder.Library.BookImport do
  @moduledoc """
  Publishes a downloaded book into the library and records the resulting file.

  The books sibling of `Cinder.Library.import_movie/1`, built on the **same** durable staging
  engine (`Cinder.Library.StageEngine`) the video imports use, so a crash mid-placement is
  recovered by the same `import_stages` journal and the same `Library.reconcile_stages/0` sweep.
  Nothing about two-phase commit is reimplemented here.

  ## Order of operations, and why

  The contract requires that "a successful import is committed only after the final path is
  durable" and that "consumer downtime cannot roll back or duplicate the import":

  1. Resolve the payload to one accepted file (`Cinder.Library.BookSources`) — refuse otherwise.
  2. Stage the placement: hardlink, or copy where a hardlink is impossible. The file is on disk
     at its final path but the operation is still reversible.
  3. Record the `book_files` row and arm the target `:available`, in one transaction
     (`Cinder.Books.Files.record_import/2`).
  4. Only if that DB write commits, commit the stage. If it fails, roll the placement back — a
     file on disk that no catalog row claims is exactly the orphan the journal exists to prevent.

  The consumer (Booklore/Audiobookshelf) is *not* notified here and its absence cannot fail the
  import: those are read/scan surfaces over the same filesystem, and the contract puts any
  notification after commit and makes it retryable.
  """
  require Logger

  alias Cinder.Books
  alias Cinder.Books.{BookGrab, BookTarget}
  alias Cinder.Download
  alias Cinder.Library
  alias Cinder.Library.{BookNaming, BookSources, StageEngine}
  alias Cinder.Settings

  @doc """
  Imports `grab`'s completed payload for its target.

  Returns `{:ok, book_file}`, or `{:error, reason}` with a reason the caller can park on. The
  grab must carry a `content_path` and have its `book_target` (with `work` and author credits)
  preloaded — `Cinder.Books.Grabs.list_downloaded/0` does exactly that.

  `opts[:replace]` (default `false`) forwards to `Cinder.Books.Files.record_import/3`: a
  confirmed "Find a better match" import supersedes the target's existing file rather than
  accumulating a second one. When something was actually superseded, the return becomes
  `{:ok, book_file, superseded_paths}` so the caller can best-effort unlink the old bytes from
  disk, post-commit; an empty (or absent) superseded list is `{:ok, book_file}` — covering both a
  fresh import and a same-path replay of an already-completed replace.
  """
  @spec import_grab(BookGrab.t(), keyword()) ::
          {:ok, struct()} | {:ok, struct(), [String.t()]} | {:error, term()}
  def import_grab(grab, opts \\ [])

  def import_grab(%BookGrab{content_path: path}, _opts) when path in [nil, ""],
    do: {:error, :missing_content_path}

  def import_grab(%BookGrab{book_target: %BookTarget{} = target} = grab, opts) do
    with {:ok, source, format} <- BookSources.resolve(grab.content_path),
         {:ok, root} <- library_root(target),
         {:ok, size} <- source_size(source) do
      place(grab, target, source, format, size, root, opts)
    end
  end

  def import_grab(%BookGrab{}, _opts), do: {:error, :book_target_not_loaded}

  defp library_root(%BookTarget{media_kind: media_kind} = target),
    do: Settings.library_root(media_kind, target)

  defp source_size(source) do
    case fs().lstat(source) do
      {:ok, %{size: size}} -> {:ok, size}
      {:error, reason} -> {:error, reason}
    end
  end

  defp place(grab, target, source, format, size, root, opts) do
    dest = BookNaming.book_dest(target.work, source, root)

    # The author/title folders are Cinder's to create, and `StageEngine` assumes the destination
    # directory exists (the movie and episode paths `mkdir_p` before staging for the same reason).
    #
    # The containment check has to come BEFORE the mkdir, not just inside the staging call after
    # it: if `books/Author` is a symlink pointing outside the library, `mkdir_p` would create
    # `outside/Title` and only then would staging reject the path — the refusal would be correct
    # but a directory outside the root would already exist. `PathPolicy.destination/3` lstats
    # every component, so a symlinked ancestor fails here and nothing is created.
    with {:ok, _vetted} <- BookSources.safe_destination(Path.dirname(dest), root),
         :ok <- fs().mkdir_p(Path.dirname(dest)),
         {:ok, rollback, placed?} <- StageEngine.stage_book_place(source, dest, root),
         {:ok, size} <- recorded_size(placed?, size, dest) do
      record(grab, target, dest, format, size, rollback, opts)
    end
  end

  # The size of the file that is actually AT the destination.
  #
  # `placed?: false` means the destination already held a different file and the contract's
  # "no automatic upgrade or conversion" rule kept it. Recording the source's size there would
  # describe bytes that were never published — the row would claim a size the file on disk does
  # not have. Re-stat the destination instead; the source's size is only right when the source
  # is what landed.
  defp recorded_size(true, source_size, _dest), do: {:ok, source_size}

  defp recorded_size(false, _source_size, dest) do
    case fs().lstat(dest) do
      {:ok, %{size: size}} -> {:ok, size}
      {:error, reason} -> {:error, reason}
    end
  end

  defp record(grab, target, dest, format, size, rollback, opts) do
    replace? = Keyword.get(opts, :replace, false)

    # The journal row must be marked `:committed` inside the same transaction as the catalog
    # write, exactly as `Catalog.transition(..., import_stage_ids:)` does for a movie: that
    # ordering is what makes a crash between the two recoverable in the right direction. A
    # rollback after this point would be undoing a committed import, so `ImportStage.mark_committed!/1`
    # runs inside `record_import/3`'s transaction and aborts it on a stale stage.
    case Books.Files.record_import(target, %{path: dest, format: format, size: size},
           import_stage_ids: Library.stage_ids([%{rollback: rollback}]),
           replace: replace?
         ) do
      {:ok, file} ->
        commit(grab, file, rollback, [])

      {:ok, file, superseded_paths} ->
        commit(grab, file, rollback, superseded_paths)

      # The catalog write lost — the target was unmonitored/held mid-import, or this exact path is
      # already claimed by another file row. Roll the placement back rather than leaving bytes on
      # disk that nothing in the catalog points at.
      {:error, reason} ->
        rollback(rollback, reason)
        {:error, reason}
    end
  end

  # `StageEngine.commit/1` directly, not `Library.commit_stage/1`: the latter's clause head
  # expects the movie/episode `%{dest:, rollback:, quality:}` shape and runs sidecar linking and
  # media-server refresh from it — video post-commit effects a book import has none of.
  defp commit(grab, file, rollback, superseded_paths) do
    case StageEngine.commit(rollback) do
      :ok ->
        finish(grab, file, superseded_paths)

      # The file row is committed and the bytes are at the destination; only the journal's
      # bookkeeping failed. Reporting an error here would re-import a file the catalog already
      # claims, so this is logged and the import stands — `reconcile_stages/0` retries the
      # journal on its own schedule.
      {:error, reason} ->
        Logger.warning(
          "book file #{file.id} imported but its stage did not commit: #{inspect(reason)}"
        )

        finish(grab, file, superseded_paths)
    end
  end

  # Post-commit, best-effort. ORDER MATTERS.
  #
  # When the removal will actually be attempted (`move_on_import` on, usenet protocol —
  # `Download.move_on_import_removal?/1`), the grab is fenced-then-deleted atomically via
  # `Download.fence_book_cleanup/1` (#415): a durable `download_intents` `:cleanup_pending` row is
  # inserted and the grab deleted in the SAME transaction, so a crash between them is impossible,
  # and a transient client-removal failure survives as that row for `reconcile_pending_intents/1`'s
  # bounded retry (every `BookPoller` tick) instead of leaking the remote job forever — the same
  # fix #411 made for the `fail_download/2` path, applied here to the success path.
  #
  # `:mismatch` (#536) means a concurrent grab already reserved a NEW intent for this same target
  # between commit and this call — fencing would have hijacked it. Degrades to the pre-#415
  # one-shot removal (`Download.fallback_remove/3`) plus a plain grab delete instead: no durable
  # record for THIS attempt, but the race winner's own intent is never touched.
  #
  # Otherwise (torrent, or `move_on_import` off — nothing will be removed from the client), the
  # grab is deleted plain. Deleting it first (rather than after) is what avoids the crash window
  # that used to matter here: a crash between a content-path delete and the grab delete would
  # leave an `:available` target, a good `book_files` row, and a surviving grab whose
  # `content_path` no longer exists — the next tick re-imports it, fails `:enoent` ten times, and
  # holds a target that is genuinely available.
  defp finish(grab, file, superseded_paths) do
    if Download.move_on_import_removal?(grab.download_protocol) do
      case Download.fence_book_cleanup(grab) do
        {:ok, intent_ids} ->
          Download.cleanup_intents(intent_ids)

        :mismatch ->
          Books.Grabs.delete(grab)

          Download.fallback_remove(
            grab.download_protocol,
            grab.download_id,
            "book target #{grab.book_target_id}"
          )
      end

      Download.best_effort_delete_source(grab.content_path)
    else
      Books.Grabs.delete(grab)
    end

    if superseded_paths == [], do: {:ok, file}, else: {:ok, file, superseded_paths}
  end

  defp rollback(rollback, reason) do
    case StageEngine.rollback(rollback) do
      :ok ->
        :ok

      {:error, rollback_error} ->
        Logger.error(
          "book import rollback failed after #{inspect(reason)}: #{inspect(rollback_error)}"
        )

        :ok
    end
  end

  defp fs, do: Application.fetch_env!(:cinder, :filesystem)
end
