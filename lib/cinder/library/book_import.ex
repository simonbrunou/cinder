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
  alias Cinder.Library
  alias Cinder.Library.{BookNaming, BookSources, StageEngine}
  alias Cinder.Settings

  @doc """
  Imports `grab`'s completed payload for its target.

  Returns `{:ok, book_file}`, or `{:error, reason}` with a reason the caller can park on. The
  grab must carry a `content_path` and have its `book_target` (with `work` and author credits)
  preloaded — `Cinder.Books.Grabs.list_downloaded/0` does exactly that.
  """
  @spec import_grab(BookGrab.t()) :: {:ok, struct()} | {:error, term()}
  def import_grab(%BookGrab{content_path: path}) when path in [nil, ""],
    do: {:error, :missing_content_path}

  def import_grab(%BookGrab{book_target: %BookTarget{} = target} = grab) do
    with {:ok, source, format} <- BookSources.resolve(grab.content_path),
         {:ok, root} <- library_root(target),
         {:ok, size} <- source_size(source) do
      place(grab, target, source, format, size, root)
    end
  end

  def import_grab(%BookGrab{}), do: {:error, :book_target_not_loaded}

  defp library_root(%BookTarget{media_kind: media_kind} = target),
    do: Settings.library_root(media_kind, target)

  defp source_size(source) do
    case fs().lstat(source) do
      {:ok, %{size: size}} -> {:ok, size}
      {:error, reason} -> {:error, reason}
    end
  end

  defp place(grab, target, source, format, size, root) do
    dest = BookNaming.book_dest(target.work, source, root)

    # The author/title folders are Cinder's to create, and `StageEngine` assumes the destination
    # directory exists (the movie and episode paths `mkdir_p` before staging for the same reason).
    # `safe_destination/2` inside the staging call still vets the full path afterwards, so this
    # cannot create a directory outside the library root that staging would then accept.
    with :ok <- fs().mkdir_p(Path.dirname(dest)),
         {:ok, rollback, _placed?} <- StageEngine.stage_book_place(source, dest, root) do
      record(grab, target, dest, format, size, rollback)
    end
  end

  defp record(grab, target, dest, format, size, rollback) do
    # The journal row must be marked `:committed` inside the same transaction as the catalog
    # write, exactly as `Catalog.transition(..., import_stage_ids:)` does for a movie: that
    # ordering is what makes a crash between the two recoverable in the right direction. A
    # rollback after this point would be undoing a committed import, so `ImportStage.mark_committed!/1`
    # runs inside `record_import/3`'s transaction and aborts it on a stale stage.
    case Books.Files.record_import(target, %{path: dest, format: format, size: size},
           import_stage_ids: Library.stage_ids([%{rollback: rollback}])
         ) do
      {:ok, file} ->
        commit(grab, file, rollback)

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
  defp commit(grab, file, rollback) do
    case StageEngine.commit(rollback) do
      :ok ->
        Books.Grabs.delete(grab)
        {:ok, file}

      # The file row is committed and the bytes are at the destination; only the journal's
      # bookkeeping failed. Reporting an error here would re-import a file the catalog already
      # claims, so this is logged and the import stands — `reconcile_stages/0` retries the
      # journal on its own schedule.
      {:error, reason} ->
        Logger.warning(
          "book file #{file.id} imported but its stage did not commit: #{inspect(reason)}"
        )

        Books.Grabs.delete(grab)
        {:ok, file}
    end
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
