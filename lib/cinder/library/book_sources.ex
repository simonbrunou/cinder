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

  ## Archives fail closed rather than being expanded

  `.rar`/`.zip`/`.7z` and split volumes are refused with `:unsupported_archive`. Meeting B4's
  "bounded entry count and expanded size, no traversal/symlink escapes" honestly requires an
  extractor — `.rar` needs an external `unrar` binary, and a zip extractor must defend against
  zip bombs and traversal entries — which is its own slice with its own tests. Until then an
  exact refusal is both what the contract asks of an unhandled payload and what `MovieSources`
  already does with `.rar`.

  `.epub` is itself a zip container, and is imported as an opaque file: it is never expanded, so
  this module opens no archive at all.

  ## Multi-format releases are one book, not an ambiguity

  `Title.epub` + `Title.mobi` is one release offering two readable copies — the same fact
  `Cinder.Acquisition.BookScorer` already accepts a multi-format release on. Files that share a
  normalized stem collapse to the single best-ranked format (`BookScorer.accepted_formats/0`,
  most-preferred first), so the allow-list and the preference order have one definition across
  the scorer and the importer.
  """
  alias Cinder.Acquisition.BookScorer
  alias Cinder.Library

  @archive_extensions ~w(.rar .zip .7z .gz .bz2 .xz .tar .cbz .cbr)

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
  def resolve(path) do
    case Library.safe_walk(path) do
      {:ok, files} -> resolve_folder(files)
      {:error, :enotdir} -> resolve_file(path)
      {:error, _reason} = error -> error
    end
  end

  defp resolve_folder(files) do
    paths = Enum.map(files, &elem(&1, 0))

    if Enum.any?(paths, &archive_file?/1),
      do: {:error, :unsupported_archive},
      else: pick(Enum.filter(paths, &accepted_file?/1))
  end

  defp resolve_file(path) do
    cond do
      archive_file?(path) -> {:error, :unsupported_archive}
      accepted_file?(path) -> validated(path)
      true -> {:error, :no_book_file}
    end
  end

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
  # enumerate every hostile file type. EPUB is a ZIP (`PK\x03\x04`); MOBI/AZW3 carry `BOOKMOBI`
  # and `TPZ3`/`MOBI` type-creator fields at byte 60 of the PalmDB header.
  defp verify_magic(path, format) do
    case fs().read_prefix(path, 68) do
      {:ok, prefix} -> if magic?(prefix, format), do: :ok, else: {:error, :format_mismatch}
      # A file whose first bytes cannot be read is not one to publish on trust.
      {:error, _reason} -> {:error, :format_mismatch}
    end
  end

  defp magic?(<<"PK", 3, 4, _rest::binary>>, :epub), do: true

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
    extension = String.downcase(Path.extname(path))
    extension in @archive_extensions or Regex.match?(~r/^\.r\d{2}$/u, extension)
  end
end
