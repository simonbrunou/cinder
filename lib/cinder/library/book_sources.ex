defmodule Cinder.Library.BookSources do
  @moduledoc """
  Resolves a completed book download to exactly one accepted file, or an explained refusal.

  The books sibling of `Cinder.Library.MovieSources`, and the validation half of B4's "validate
  downloaded files/archives before publication".

  ## What each guarantee is actually enforced by

  - **regular files only, no traversal, no symlink escape** — `Cinder.Library.PathPolicy` `lstat`s
    every path component and refuses anything that is not a regular file under a configured import
    root. Reused through `Cinder.Library.safe_walk/1` and `safe_book_source/1`, never
    reimplemented here.
  - **no executable substitution** — the extension list is a *positive* allow-list, so a
    `book.epub.exe`, a bare ELF, or a `.pdf` scan is `:no_book_file` rather than something to
    reason about.
  - **no mixed unrelated release** — two accepted files whose names disagree is
    `:ambiguous_book_files`. Never "pick the biggest": for video that heuristic picks the feature
    out of samples and extras, but two book files of similar size are as likely to be two
    different books, and importing the wrong one is a silent wrong answer.

  ## Archives are extracted, bounded — except `.7z` and a genuinely mixed folder

  `.zip`/`.cbz` extract through `Cinder.Library.BookArchive.Zip` (pure OTP, no external
  dependency); `.rar`/`.cbr`, and a split `.rNN` set (resolved to its `.rar` main volume, the
  others located by `unrar` itself), through `Cinder.Library.BookArchive.Rar` — only when
  `unrar` is on `PATH`, checked fresh at resolve time, never cached. Every extractor enforces
  an entry-count ceiling, an expanded-size ceiling checked *during* decompression rather than
  after, and refuses any entry whose path would escape the extraction root or that is not a
  regular file — see each extractor's own moduledoc for exactly how, and why (both were built
  only after establishing what Erlang's own `:zip` module can and cannot verify).

  `.7z`, and a folder that mixes an archive with other loose files, still refuse outright with
  `:unsupported_archive` — the former because nothing here parses that format at all, the
  latter because a release that is simultaneously "an archive" and "some other file" is rare
  enough, and ambiguous enough about which one is the release, to be out of scope rather than
  guessed at. So does a nested archive found *inside* an already-extracted one — `resolve/1`
  recurses into the extracted scratch directory exactly once; anything unresolved there,
  archives included, is a plain refusal, not a second extraction attempt.

  `Cinder.Library.BookArchive.extract_and_resolve/2` hands the extracted scratch directory to
  this exact `resolve/1`, so the extension allow-list, `verify_magic/2`, and the multi-format
  collapse below all still gate whatever an archive contained — extraction cannot widen what
  publishes, because nothing downstream of it is new code.

  `.epub` is itself a zip container, and is imported as an opaque file: it is never expanded on
  this path, extension list included — unpacking it would change what publishes for an
  already-working format.

  ## Multi-format releases are one book, not an ambiguity

  `Title.epub` + `Title.mobi` is one release offering two readable copies — the same fact
  `Cinder.Acquisition.BookScorer` already accepts a multi-format release on. Files that share a
  normalized stem collapse to the single best-ranked format (`BookScorer.accepted_formats/0`,
  most-preferred first), so the allow-list and the preference order have one definition across
  the scorer and the importer.
  """
  alias Cinder.Acquisition.BookScorer
  alias Cinder.Library
  alias Cinder.Library.BookArchive

  @archive_extensions ~w(.rar .zip .7z .gz .bz2 .xz .tar .cbz .cbr)
  @extractable_extensions ~w(.zip .cbz .rar .cbr)

  @doc "The file extensions an import accepts, most-preferred format first."
  @spec accepted_extensions() :: [String.t()]
  def accepted_extensions, do: Enum.map(BookScorer.accepted_formats(), &".#{&1}")

  @doc """
  The book equivalent of `Cinder.Library.safe_source_file/1`.

  Same containment and lstat-every-component symlink refusal, different extension allow-list.
  A separate function rather than a parameter on the video one so a book extension can never
  widen what a video import accepts.
  """
  @spec safe_source(String.t()) :: {:ok, String.t()} | {:error, term()}
  def safe_source(path), do: Cinder.Library.safe_source_file(path, accepted_extensions())

  @doc """
  Vets the destination DIRECTORY of a book import before it is created.

  Separate from the containment check inside staging, and earlier than it: if `books/Author` is a
  symlink pointing outside the library, `mkdir_p` would create `outside/Title` and only then would
  staging reject the path. The refusal would be correct but the outside-root directory would
  already exist.
  """
  @spec safe_destination(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def safe_destination(path, root),
    do: Cinder.Library.path_policy().destination(path, root, filesystem: fs())

  @doc """
  Resolves `path` — a completed download's file or directory — to `{:ok, source, format}`.

  `format` is the accepted format atom, so the caller records what it actually imported rather
  than re-deriving it from the destination name.
  """
  @spec resolve(String.t()) ::
          {:ok, String.t(), atom()}
          | {:error, :no_book_file | :ambiguous_book_files | :unsupported_archive | term()}
  def resolve(path), do: resolve(path, true)

  # `extract?` bounds recursion to exactly one archive-extraction attempt: the scratch
  # directory `Cinder.Library.BookArchive.extract_and_resolve/2` hands back here is resolved
  # with `extract?: false`, so an archive found INSIDE an already-extracted one is a plain
  # `:unsupported_archive` refusal rather than a second extraction — see the moduledoc.
  defp resolve(path, extract?) do
    case Library.safe_walk(path) do
      {:ok, files} -> resolve_folder(files, extract?)
      {:error, :enotdir} -> resolve_file(path, extract?)
      {:error, _reason} = error -> error
    end
  end

  defp resolve_folder(files, extract?) do
    all_paths = Enum.map(files, &elem(&1, 0))
    paths = if extract?, do: Enum.reject(all_paths, &scratch_path?/1), else: all_paths

    case archive_candidate(paths) do
      {:ok, archive_path} when extract? ->
        BookArchive.extract_and_resolve(archive_path, &resolve(&1, false))

      {:ok, _archive_path} ->
        {:error, :unsupported_archive}

      :none ->
        pick(Enum.filter(paths, &accepted_file?/1))

      {:error, _reason} = error ->
        error
    end
  end

  defp resolve_file(path, extract?) do
    cond do
      extractable_archive?(path) and extract? ->
        BookArchive.extract_and_resolve(path, &resolve(&1, false))

      archive_file?(path) ->
        {:error, :unsupported_archive}

      accepted_file?(path) ->
        validated(path)

      true ->
        {:error, :no_book_file}
    end
  end

  # Applied only when resolving the pre-extraction folder (`extract?: true`) — never a second
  # extraction attempt's own artifacts read back as a second, unrelated candidate. Once
  # recursed INTO the scratch directory itself (`extract?: false`), every remaining path
  # necessarily carries this same name as a path segment, so the filter is skipped there; see
  # `Cinder.Library.BookArchive`'s moduledoc on why the scratch directory has a fixed, reserved
  # name instead of a random one.
  defp scratch_path?(path), do: BookArchive.scratch_dir_name() in Path.split(path)

  # `archives == []` is the common case (nothing to extract, fall through to the normal
  # accepted-file pick). Exactly one archive and nothing else alongside it is the only
  # extractable shape: either a single `.zip`/`.cbz`/`.rar`/`.cbr`, or a split `.rNN` set whose
  # one `.rar`/`.cbr` main volume is the file `unrar` is pointed at (it locates the numbered
  # siblings itself). Anything else — a folder mixing an archive with other loose files,
  # multiple distinct archives, a `.rNN` set with no main volume present, or a lone `.7z` — is
  # `:unsupported_archive`, exactly as before this feature existed.
  defp archive_candidate(paths) do
    archives = Enum.filter(paths, &archive_file?/1)
    non_archives = paths -- archives

    cond do
      archives == [] -> :none
      non_archives != [] -> {:error, :unsupported_archive}
      true -> pick_archive(archives)
    end
  end

  defp pick_archive(archives) do
    mains = Enum.filter(archives, &rar_main?/1)
    zips = Enum.filter(archives, &zip_like?/1)
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

  defp extractable_archive?(path),
    do: String.downcase(Path.extname(path)) in @extractable_extensions

  defp zip_like?(path), do: String.downcase(Path.extname(path)) in ~w(.zip .cbz)
  defp rar_main?(path), do: String.downcase(Path.extname(path)) in ~w(.rar .cbr)
  defp rar_volume?(path), do: Regex.match?(~r/^\.r\d{2}$/u, String.downcase(Path.extname(path)))

  defp pick([]), do: {:error, :no_book_file}

  # The multi-candidate collapse exists for ONE case: the same book offered in several formats
  # (`Title.epub` + `Title.mobi`), where taking the preferred format is right.
  #
  # Both conditions are required. A shared stem alone is not enough, because `Library.safe_walk/1`
  # recurses: `Retail/Foundation.epub` and `Proof/Foundation.epub` share a stem while being two
  # different files, and picking one by `format_rank/1` would break the tie arbitrarily on walk
  # order — the silent wrong answer this module refuses to produce. Requiring the formats to be
  # distinct as well means a duplicated format is always `:ambiguous_book_files`.
  defp pick(candidates) do
    stems = candidates |> Enum.map(&stem/1) |> Enum.uniq()
    formats = candidates |> Enum.map(&format/1) |> Enum.uniq()

    if length(stems) == 1 and length(formats) == length(candidates) do
      candidates |> Enum.min_by(&format_rank/1) |> validated()
    else
      {:error, :ambiguous_book_files}
    end
  end

  defp validated(path) do
    with {:ok, source} <- safe_source(path),
         format = format(source),
         :ok <- verify_magic(source, format) do
      {:ok, source, format}
    end
  end

  # The extension says what the file CLAIMS to be; the first bytes say what it is. Without this
  # the allow-list was a filename-suffix check: an ELF or PE renamed `book.epub` passed every
  # containment and extension gate, published into the library, and marked the target available.
  #
  # Positive identification, not executable-blocklisting: each accepted format has a documented
  # signature, so anything that is not recognisably that format is refused rather than trying to
  # enumerate every hostile file type. MOBI/AZW3 carry `BOOKMOBI` and `TPZ3`/`MOBI` type-creator
  # fields at byte 60 of the PalmDB header.
  #
  # EPUB needs more than `PK\x03\x04`. That signature says "some ZIP", and `.zip` is a format this
  # module refuses outright — so a renamed archive walked through the extension gate, the
  # signature gate, and published as an available book that no reader can open. OCF pins the rest
  # of it: the first entry of an EPUB container MUST be a `mimetype` file, stored uncompressed
  # with no extra field, whose content is `application/epub+zip`. A conforming container therefore
  # carries that exact 28-byte run at offset 30, right after the 30-byte local file header — well
  # inside the prefix already being read for MOBI.
  #
  # The cost is that a non-conforming EPUB (a repacker that compressed `mimetype`) is refused. That
  # is a visible `:format_mismatch` hold naming the file, not a silent wrong answer, and it is the
  # trade this module's own "never pick, refuse" rule asks for.
  defp verify_magic(path, format) do
    case fs().read_prefix(path, 68) do
      {:ok, prefix} -> if magic?(prefix, format), do: :ok, else: {:error, :format_mismatch}
      # A file whose first bytes cannot be read is not one to publish on trust.
      {:error, _reason} -> {:error, :format_mismatch}
    end
  end

  defp magic?(
         <<"PK", 3, 4, _header::binary-size(26), "mimetypeapplication/epub+zip", _rest::binary>>,
         :epub
       ),
       do: true

  defp magic?(<<_head::binary-size(60), "BOOKMOBI", _rest::binary>>, format)
       when format in [:mobi, :azw3],
       do: true

  defp magic?(<<_head::binary-size(60), "TPZ3", _rest::binary>>, :azw3), do: true
  defp magic?(_prefix, _format), do: false

  # The format preference order is the scorer's, by index — one definition of "epub beats mobi"
  # rather than a second list here that could drift from the one releases are scored on.
  defp format_rank(path),
    do: Enum.find_index(BookScorer.accepted_formats(), &(&1 == format(path)))

  # Looked up in the allow-list rather than converted from the string: `String.to_existing_atom/1`
  # on a path extension turns attacker-influenced filenames into atom lookups, and every caller
  # here has already passed `accepted_file?/1`, so the lookup always hits.
  defp format(path) do
    extension = String.downcase(Path.extname(path))
    Enum.find(BookScorer.accepted_formats(), &(".#{&1}" == extension))
  end

  defp accepted_file?(path),
    do: String.downcase(Path.extname(path)) in accepted_extensions()

  defp fs, do: Application.fetch_env!(:cinder, :filesystem)

  # Normalized so `Title.epub` and `Title.mobi` collapse to one book while `Book One.epub` and
  # `Book Two.epub` stay two. Separators and case are noise; the words are not.
  defp stem(path) do
    path
    |> Path.basename()
    |> Path.rootname()
    |> String.downcase()
    |> String.replace(~r/[ ._-]+/u, " ")
    |> String.trim()
  end

  # `.r00`-style split volumes alongside the named archive extensions: a multipart RAR set is
  # still an archive, and its first part often carries the only recognizable extension.
  defp archive_file?(path) do
    String.downcase(Path.extname(path)) in @archive_extensions or rar_volume?(path)
  end
end
