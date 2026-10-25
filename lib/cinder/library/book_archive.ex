defmodule Cinder.Library.BookArchive do
  @moduledoc """
  The archive half of both book resolvers (`Cinder.Library.EbookSources.resolve/1` and
  `Cinder.Library.AudiobookSources.resolve/1`): `archive_candidate/1` decides which one archive
  in a download folder to extract, and `extract_and_resolve/3` dispatches it to the right bounded
  extractor (`Cinder.Library.BookArchive.Zip` or `.Rar`), then hands the result to the caller's
  resolver — the same function every other candidate of that kind goes through, so extraction
  cannot widen what publishes and the ambiguity/multi-format rules stay exactly what they
  already are. One definition serves both book kinds, as ADR 0001 has it for the release judge.

  `.7z` and every other archive `archive?/1` flags but `extractable?/1` does not is deliberately
  not dispatched here — those extensions never reach `extract_and_resolve/3` at all, and stay the
  plain `:unsupported_archive` refusal.

  ## Companions

  Scene and usenet releases ship their `.rar` set with an `.nfo` and an `.sfv`, and public-tracker
  releases add a 0-byte `RARBG_DO_NOT_MIRROR.exe`. `archive_candidate/1` picks a folder's one
  archive for extraction (a `.rar` main volume together with its `.rNN` volumes) when every other
  file beside it is a companion, a file that can never be the book: `.nfo`, `.sfv`, `.md5`,
  `.par2`, `.txt`, `.url`, `.jpg`, `.jpeg`, `.png`, and every extension in
  `Cinder.Download.ContentPolicy.blocked_extensions/0` (`.exe`, `.lnk`, ... by default). The
  blocked list is read at call time, so an install's configured list counts too, and a blocked
  file is a companion whatever its size (#781).

  Those nine extensions are fixed on purpose. Any other file beside an archive could be the
  release, or a second book: an accepted format of either kind, an audio file an audiobook import
  refuses (`.flac`, `.m4a`, ...), a second archive `archive?/1` flags, or an unknown extension.
  Each of those keeps the folder an `:unsupported_archive` refusal rather than a guess. (`.zipx`
  is on `ContentPolicy`'s default blocked list, so it counts as a companion, not a second
  archive.)

  A companion matches on its plain extension. `ContentPolicy` also reads a name with a trailing
  dot or an alternate-data-stream suffix (`x.exe.`, `x.exe:$DATA`) as blocked; beside an archive
  such a file is not a companion and the folder still refuses. That can only hold a release,
  never publish a wrong one.

  A companion is never published: it sits beside the archive, outside the scratch directory, and
  only what the extracted archive resolves to reaches the library.

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

  Each resolver's own directory walk excludes this exact reserved name (`scratch_dir_name/0`)
  before `archive_candidate/1` sees the folder, so neither a fresh nor an orphaned instance is
  ever mistaken for a second, unrelated book file.
  """

  alias Cinder.Download.ContentPolicy
  alias Cinder.Library
  alias Cinder.Library.BookArchive.{Rar, Zip}

  @scratch_dir_name ".cinder-extract"
  @archive_extensions ~w(.rar .zip .7z .gz .bz2 .xz .tar .cbz .cbr)
  @zip_extensions ~w(.zip .cbz)
  @rar_extensions ~w(.rar .cbr)
  @extractable_extensions @zip_extensions ++ @rar_extensions
  @companion_extensions ~w(.nfo .sfv .md5 .par2 .txt .url .jpg .jpeg .png)

  @doc "The reserved scratch-directory basename — excluded from every folder candidate scan."
  @spec scratch_dir_name() :: String.t()
  def scratch_dir_name, do: @scratch_dir_name

  @doc """
  Whether `path` is an archive, extractable or not. `.rNN`-style split volumes count alongside
  the named archive extensions: a multipart RAR set is still an archive, and its first part
  often carries the only recognizable extension.
  """
  @spec archive?(String.t()) :: boolean()
  def archive?(path), do: extension(path) in @archive_extensions or rar_volume?(path)

  @doc "Whether `path` is an archive `extract_and_resolve/3` extracts: `.zip`/`.cbz`/`.rar`/`.cbr`."
  @spec extractable?(String.t()) :: boolean()
  def extractable?(path), do: extension(path) in @extractable_extensions

  @doc """
  Picks the one archive to extract from a download folder's walked `paths`.

  `:none` when no path is an archive: the caller resolves the loose files as they are. `{:ok,
  archive_path}` when exactly one archive sits there with nothing but companions beside it (see
  the moduledoc): either a single `.zip`/`.cbz`/`.rar`/`.cbr`, or a split `.rNN` set whose one
  `.rar`/`.cbr` main volume is the file `unrar` is pointed at (it locates the numbered siblings
  itself). Anything else — an archive beside a file off the companion list, multiple distinct
  archives, a `.rNN` set with no main volume present, or a lone `.7z` — is
  `{:error, :unsupported_archive}`.
  """
  @spec archive_candidate([String.t()]) ::
          :none | {:ok, String.t()} | {:error, :unsupported_archive}
  def archive_candidate(paths) do
    archives = Enum.filter(paths, &archive?/1)
    non_archives = Enum.reject(paths -- archives, &companion?/1)

    cond do
      archives == [] -> :none
      non_archives != [] -> {:error, :unsupported_archive}
      true -> pick_archive(archives)
    end
  end

  defp pick_archive(archives) do
    mains = Enum.filter(archives, &(extension(&1) in @rar_extensions))
    zips = Enum.filter(archives, &(extension(&1) in @zip_extensions))
    # NOTE: `--` is right-associative in Elixir (unlike arithmetic `-`) - parens are load-bearing,
    # not stylistic; `archives -- mains -- zips` silently no-ops to `archives` whenever `mains`
    # is empty, which is every zip-only release.
    volumes = (archives -- mains) -- zips

    cond do
      zips == [] and length(mains) == 1 and Enum.all?(volumes, &rar_volume?/1) ->
        {:ok, hd(mains)}

      mains == [] and volumes == [] and length(zips) == 1 ->
        {:ok, hd(zips)}

      true ->
        {:error, :unsupported_archive}
    end
  end

  # Read at call time, never copied, so an install's configured blocked list counts too.
  defp companion?(path) do
    extension = extension(path)
    extension in @companion_extensions or extension in ContentPolicy.blocked_extensions()
  end

  defp rar_volume?(path), do: Regex.match?(~r/^\.r\d{2}$/u, extension(path))

  defp extension(path), do: String.downcase(Path.extname(path))

  @doc """
  Extracts `archive_path` (already confirmed to be a `.zip`/`.cbz`/`.rar`/`.cbr` —
  `archive_candidate/1` picks which single archive a folder holds, including resolving a split
  `.rNN` set to its `.rar` main volume; this function only ever handles one file) to the
  scratch directory, then calls `resolve_fun` on it. The scratch directory survives a success
  (see the moduledoc); a failure removes it, so a refused attempt does not accumulate partial
  extraction garbage under the import root.

  `opts` (`:max_entries`, `:max_expanded_size`) is forwarded to whichever extractor `extract/3`
  dispatches to — both `Zip.extract/3` and `Rar.extract/3` already accept and apply it, but this
  module itself never passed any until `Cinder.Library.AudiobookSources.resolve/1` needed the
  audiobook profile's own 8 GB ceiling instead of the e-book-tuned 1 GB extractor default.
  `Cinder.Library.EbookSources.resolve/1`'s own call site is unchanged: `opts` defaults to `[]`,
  exactly what it passed by omission before this arity grew.
  """
  @spec extract_and_resolve(String.t(), (String.t() -> result), keyword()) ::
          result | {:error, term()}
        when result: term()
  def extract_and_resolve(archive_path, resolve_fun, opts \\ []) do
    with {:ok, safe_path} <- safe_archive_source(archive_path),
         scratch_dir = Path.join(Path.dirname(safe_path), @scratch_dir_name),
         :ok <- reset_scratch_dir(scratch_dir) do
      # Once `reset_scratch_dir/1` has succeeded, this attempt owns `scratch_dir` — an extractor
      # refusal (a size/CRC ceiling, a corrupt archive) can already have written partial output
      # under it, same as a resolver refusal, so both flow through the same `finish/2` cleanup
      # (#507). Before this point (a rejected/outside-root archive_path), nothing has been
      # written under this attempt's ownership, so there is nothing to clean up.
      case extract(safe_path, scratch_dir, opts) do
        :ok -> finish(resolve_fun.(scratch_dir), scratch_dir)
        {:error, _reason} = error -> finish(error, scratch_dir)
      end
    else
      {:error, _reason} = error -> error
    end
  end

  # The one containment/symlink/extension check every other candidate this module hands to
  # `resolve/1` already gets — a resolver's `resolve_folder/2` already validated it via
  # `Library.safe_walk/1`, but its `resolve_file/2` hands a bare archive path here with no
  # containment check of its own. Closing that gap here means extraction never even opens a path
  # this module has not itself confirmed is safe to read.
  defp safe_archive_source(archive_path),
    do: Library.safe_source_file(archive_path, @extractable_extensions)

  defp reset_scratch_dir(scratch_dir) do
    with {:ok, _removed} <- File.rm_rf(scratch_dir) do
      File.mkdir_p(scratch_dir)
    end
  end

  defp extract(archive_path, scratch_dir, opts) do
    extension = extension(archive_path)

    cond do
      extension in @zip_extensions -> Zip.extract(archive_path, scratch_dir, opts)
      extension in @rar_extensions -> Rar.extract(archive_path, scratch_dir, opts)
      true -> {:error, :unsupported_archive}
    end
  end

  # Generic on purpose: `resolve_fun`'s own type is `(String.t() -> result) when result: term()`
  # (see `extract_and_resolve/3`'s spec) — `EbookSources.resolve/1`'s resolve_fun returns a
  # 3-tuple (`{:ok, source, format}`), `Cinder.Library.AudiobookSources.resolve/1`'s returns a
  # 2-tuple (`{:ok, tracks}`). A clause that only matched the 3-tuple shape left every SUCCESSFUL
  # audiobook extraction raising `FunctionClauseError` here (caught only by the poller's
  # `isolate/2` rescue, so it surfaced as an opaque logged failure, never a working import) — the
  # `:error` clause is the only shape this function needs to special-case; anything else a
  # `resolve_fun` returns is success, unconditionally.
  defp finish({:error, _reason} = error, scratch_dir) do
    _ = File.rm_rf(scratch_dir)
    error
  end

  defp finish(ok_result, _scratch_dir), do: ok_result
end
