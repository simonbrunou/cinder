defmodule Cinder.Library.EbookImport do
  @moduledoc """
  Publishes a downloaded e-book into the library and records the resulting file.

  The e-book sibling of `Cinder.Library.stage_movie/2`, built on the **same** staged import
  (`Cinder.Library.StagedImport`) the video imports use, so a crash mid-placement is recovered by
  the same `import_stages` journal and the same `StagedImport.reconcile/0` sweep. Nothing about
  two-phase commit is reimplemented here.

  ## Order of operations, and why

  The contract requires that "a successful import is committed only after the final path is
  durable" and that "consumer downtime cannot roll back or duplicate the import":

  1. Resolve the payload to one accepted file (`Cinder.Library.EbookSources`) — refuse otherwise.
  2. Stage the placement: hardlink, or copy where a hardlink is impossible. The file is on disk
     at its final path but the operation is still reversible.
  3. Record the `book_files` row and arm the target `:available`, in one transaction
     (`Cinder.Books.Files.record_import/3`), which also marks the stage committed.
  4. The staged import commits the stage only if that write committed, and rolls the placement
     back otherwise — a file on disk that no catalog row claims is exactly the orphan the journal
     exists to prevent.

  The consumer (Booklore/Audiobookshelf) is *not* notified here and its absence cannot fail the
  import: those are read/scan surfaces over the same filesystem, and the contract puts any
  notification after commit and makes it retryable.
  """
  alias Cinder.Books
  alias Cinder.Books.{BookGrab, BookTarget}
  alias Cinder.Download
  alias Cinder.Library.{EbookNaming, EbookSources, StagedImport}
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
    do: {:error, :no_content_path}

  def import_grab(%BookGrab{book_target: %BookTarget{} = target} = grab, opts) do
    with {:ok, source, format} <- EbookSources.resolve(grab.content_path),
         {:ok, root} <- library_root(target),
         {:ok, size} <- source_size(source) do
      place(grab, target, source, format, size, root, Keyword.get(opts, :replace, false))
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

  # A collision keeps the existing file unless this is a confirmed replace: the parity contract
  # parks automatic upgrades and format conversion for the first release, so an operator's copy
  # is never overwritten on the strength of a release name.
  defp place(grab, target, source, format, size, root, replace?) do
    dest = EbookNaming.book_dest(target.work, source, root)

    # The author/title folders are Cinder's to create, and staging assumes the destination
    # directory exists (the movie and episode paths `mkdir_p` before staging for the same reason).
    #
    # The containment check has to come BEFORE the mkdir, not just inside the staging call after
    # it: if `books/Author` is a symlink pointing outside the library, `mkdir_p` would create
    # `outside/Title` and only then would staging reject the path — the refusal would be correct
    # but a directory outside the root would already exist. `PathPolicy.destination/3` lstats
    # every component, so a symlinked ancestor fails here and nothing is created.
    with {:ok, _vetted} <- EbookSources.safe_destination(Path.dirname(dest), root),
         :ok <- fs().mkdir_p(Path.dirname(dest)),
         {:ok, staged, outcome} <-
           StagedImport.place(StagedImport.new(), source, dest, root,
             on_collision: if(replace?, do: :replace, else: :keep),
             extensions: EbookSources.accepted_extensions()
           ) do
      case recorded_size(outcome, size, dest) do
        {:ok, size} ->
          staged
          |> StagedImport.put_record(%{path: dest, format: format, size: size})
          |> record(grab, target, replace?)

        {:error, _reason} = error ->
          StagedImport.rollback(staged)
          error
      end
    end
  end

  # The size of the file that is actually AT the destination.
  #
  # Only a placement or a replacement published the source's bytes. Otherwise the destination
  # already held a file and the contract's "no automatic upgrade or conversion" rule kept it (or
  # it is this very file, replayed). Recording the source's size there would describe bytes that
  # were never published — the row would claim a size the file on disk does not have. Re-stat the
  # destination instead.
  defp recorded_size(outcome, source_size, _dest) when outcome in [:placed, :replaced],
    do: {:ok, source_size}

  defp recorded_size(_outcome, _source_size, dest) do
    case fs().lstat(dest) do
      {:ok, %{size: size}} -> {:ok, size}
      {:error, reason} -> {:error, reason}
    end
  end

  # `record_import/3` marks the stage committed inside its own transaction, exactly as
  # `MovieLifecycle.import_staged/2` does for a movie: that ordering is what makes a crash between
  # the two recoverable in the right direction. A losing write (the target was unmonitored or
  # held mid-import, or this exact path is already claimed by another file row) commits nothing,
  # so the placement rolls back.
  defp record(staged, grab, target, replace?) do
    write = &Books.Files.record_import(target, &1, import_stage_ids: &2, replace: replace?)

    case StagedImport.commit(staged, write) do
      {:ok, file} ->
        Download.release_imported_book_grab(grab)
        {:ok, file}

      {:ok, file, []} ->
        Download.release_imported_book_grab(grab)
        {:ok, file}

      {:ok, file, superseded_paths} ->
        Download.release_imported_book_grab(grab)
        {:ok, file, superseded_paths}

      {:error, _reason} = error ->
        error
    end
  end

  defp fs, do: Application.fetch_env!(:cinder, :filesystem)
end
