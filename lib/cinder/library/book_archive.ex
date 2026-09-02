defmodule Cinder.Library.BookArchive do
  @moduledoc """
  Dispatches a single archive file to the right bounded extractor
  (`Cinder.Library.BookArchive.Zip` or `.Rar`), then hands the result to
  `Cinder.Library.BookSources.resolve/1` — the same function every other candidate goes
  through, so extraction cannot widen what publishes and the ambiguity/multi-format rules stay
  exactly what they already are.

  `.7z` and everything else `Cinder.Library.BookSources`'s own `archive_file?/1` still flags is
  deliberately not dispatched here — those extensions never reach `extract_and_resolve/2` at
  all, and stay the plain `:unsupported_archive` refusal.

  ## Scratch directory

  A single, fixed-name (`.cinder-extract`, not randomly generated per attempt) hidden
  subdirectory, created as a sibling of the archive — always under whichever import root the
  archive itself already lives under, since `resolve/1`'s callers only ever reach here with an
  already-`Library.safe_walk/1`-validated path.

  Wiped and recreated at the START of every extraction attempt, not cleaned up afterward on
  success. Two things fall out of that one choice:

  - **Self-healing from a crash.** A VM kill or power loss mid-extraction leaves the scratch
    directory behind; the wipe on the NEXT attempt (the poller's next retry tick, since an
    unresolved archive never leaves the target anywhere but `:monitored`) clears it without
    needing a separate reaper process.
  - **Idempotent re-polling.** A second resolution of the same folder (e.g. a crash between a
    successful extraction and the rest of the import completing) wipes-and-redoes the identical
    extraction from the same, untouched original archive — not a second, differently-named
    artifact competing with the first as a loose candidate file.

  `Cinder.Library.BookSources.resolve_folder/1`'s own directory walk excludes this exact
  reserved name unconditionally (`scratch_dir_name/0`), so neither a fresh nor an orphaned
  instance is ever mistaken for a second, unrelated book file.
  """

  alias Cinder.Library
  alias Cinder.Library.BookArchive.{Rar, Zip}

  @scratch_dir_name ".cinder-extract"
  @zip_extensions ~w(.zip .cbz)
  @rar_extensions ~w(.rar .cbr)

  @doc "The reserved scratch-directory basename — excluded from every folder candidate scan."
  @spec scratch_dir_name() :: String.t()
  def scratch_dir_name, do: @scratch_dir_name

  @doc """
  Extracts `archive_path` (already confirmed to be a `.zip`/`.cbz`/`.rar`/`.cbr` — the caller
  picks which single archive this is, including resolving a split `.rNN` set to its `.rar`
  main volume; this module only ever handles one file) to the scratch directory, then calls
  `resolve_fun` on it. The scratch directory survives a success (see the moduledoc); a failure
  removes it, so a refused attempt does not accumulate partial extraction garbage under the
  import root.

  `opts` (`:max_entries`, `:max_expanded_size`) is forwarded to whichever extractor `extract/3`
  dispatches to — both `Zip.extract/3` and `Rar.extract/3` already accept and apply it, but this
  module itself never passed any until `Cinder.Library.AudiobookSources.resolve/1` needed the
  audiobook profile's own 8 GB ceiling instead of the e-book-tuned 1 GB extractor default.
  `Cinder.Library.BookSources.resolve/1`'s own call site is unchanged: `opts` defaults to `[]`,
  exactly what it passed by omission before this arity grew.
  """
  @spec extract_and_resolve(String.t(), (String.t() -> result), keyword()) ::
          result | {:error, term()}
        when result: term()
  def extract_and_resolve(archive_path, resolve_fun, opts \\ []) do
    with {:ok, safe_path} <- safe_archive_source(archive_path),
         scratch_dir = Path.join(Path.dirname(safe_path), @scratch_dir_name),
         :ok <- reset_scratch_dir(scratch_dir),
         :ok <- extract(safe_path, scratch_dir, opts) do
      finish(resolve_fun.(scratch_dir), scratch_dir)
    else
      {:error, _reason} = error -> error
    end
  end

  # The one containment/symlink/extension check every other candidate this module hands to
  # `resolve/1` already gets — `resolve_folder/1`'s callers already validated it via
  # `Library.safe_walk/1`, but `resolve_file/1`'s single-path caller has not, since today it
  # refuses an archive before ever reaching a containment check. Closing that gap here means
  # extraction never even opens a path this module has not itself confirmed is safe to read.
  defp safe_archive_source(archive_path),
    do: Library.safe_source_file(archive_path, @zip_extensions ++ @rar_extensions)

  defp reset_scratch_dir(scratch_dir) do
    with {:ok, _removed} <- File.rm_rf(scratch_dir) do
      File.mkdir_p(scratch_dir)
    end
  end

  defp extract(archive_path, scratch_dir, opts) do
    extension = String.downcase(Path.extname(archive_path))

    cond do
      extension in @zip_extensions -> Zip.extract(archive_path, scratch_dir, opts)
      extension in @rar_extensions -> Rar.extract(archive_path, scratch_dir, opts)
      true -> {:error, :unsupported_archive}
    end
  end

  defp finish({:ok, _source, _format} = ok, _scratch_dir), do: ok

  defp finish({:error, _reason} = error, scratch_dir) do
    _ = File.rm_rf(scratch_dir)
    error
  end
end
