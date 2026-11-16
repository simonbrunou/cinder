defmodule Cinder.Library.EbookNaming do
  @moduledoc """
  Where an imported e-book lands: `root/Author/Title/<original filename>`.

  ## The filename is the release's, on purpose

  The parity contract locks this:

  > Automatic renaming remains **off** for migration parity. **Preserve release filenames** is the
  > B0 default.

  So this module names *directories* and preserves the source's basename. That is not a
  placeholder for a renamer — a B6 adoption pass has to recognize files Cinder itself wrote and
  files Bookshelf wrote as the same layout, and renaming on import would make those two
  populations differ.

  ## The catalog names the folders, never the release

  `Author/Title` comes from `Cinder.Books.Work` and its author credits, so a release whose name
  lies about the author cannot steer a file into another author's folder. The two folders come
  from `Cinder.Library.BookFolders`, which audiobooks share. Every component is sanitized the
  same way `Cinder.Library.Naming` sanitizes a movie title, and `PathPolicy` still vets the
  result — the contract's "no provider title is allowed to escape the configured library root"
  is enforced twice, lexically here and by `lstat` there.

  A work with no author credit lands under `Unknown Author` rather than at the library root: the
  contract's fail-closed rule is about identity resolution and grabbing, and by import time an
  operator has already approved this target. A file directly in the root would be one Bookshelf
  cannot attribute and B6 cannot adopt.
  """
  alias Cinder.Books.Work
  import Cinder.Library.BookFolders, only: [author_folder: 1, title_folder: 1, sanitize: 1]

  @doc """
  The destination for `source` under `root`, for a target's `work`.

  The basename is `source`'s, unchanged apart from the same illegal-character sanitizing every
  other component gets: only the directories are Cinder's.
  """
  @spec ebook_dest(Work.t(), String.t(), String.t()) :: String.t()
  def ebook_dest(%Work{} = work, source, root),
    do: Path.join([root, author_folder(work), title_folder(work), file_name(source)])

  # `Path.basename/1` already drops any directory part, so a release-supplied `../../etc/passwd`
  # cannot survive as a path. It does NOT drop a bare `..`, and a dots-only name would become a
  # segment that climbs out of the library root, so `BookFolders.sanitize/1` runs on the basename
  # too. A name that sanitizes away entirely — or down to a LEADING DOT, which would publish a
  # hidden file the consumer's scanner skips (`???.epub` sanitizes to `.epub`) — keeps its
  # extension and gets a neutral stem instead. Belt and braces: `PathPolicy.destination/3` vets
  # the joined path again before anything is written.
  defp file_name(source) do
    basename = Path.basename(source)

    case sanitize(basename) do
      "" -> "book" <> fallback_extension(basename)
      "." <> _rest -> "book" <> fallback_extension(basename)
      name -> name
    end
  end

  # The extension carried onto the neutral stem is itself sanitized: `Path.extname("..")` is
  # `"."`, which would produce a trailing-dot filename, and an extension of illegal characters
  # would reintroduce exactly what `BookFolders.sanitize/1` just removed. Anything that does not
  # survive as a plain alphanumeric suffix is dropped entirely — the file still imports, under a
  # safe name.
  defp fallback_extension(basename) do
    case String.downcase(Path.extname(basename)) do
      "." <> rest = extension when rest != "" ->
        if String.match?(rest, ~r/\A[a-z0-9]+\z/u), do: extension, else: ""

      _no_usable_extension ->
        ""
    end
  end
end
