defmodule Cinder.Library.BookNaming do
  @moduledoc """
  Where an imported book lands: `root/Author/Title/<original filename>`.

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
  lies about the author cannot steer a file into another author's folder. Every component is
  sanitized the same way `Cinder.Library.Naming` sanitizes a movie title, and `PathPolicy` still
  vets the result — the contract's "no provider title is allowed to escape the configured library
  root" is enforced twice, lexically here and by `lstat` there.

  A work with no author credit lands under `Unknown Author` rather than at the library root: the
  contract's fail-closed rule is about identity resolution and grabbing, and by import time an
  operator has already approved this target. A file directly in the root would be one Bookshelf
  cannot attribute and B6 cannot adopt.
  """
  alias Cinder.Books.Work
  alias Cinder.Library.Naming

  @illegal ~r/[\/\\:*?"<>|]/
  @unknown_author "Unknown Author"

  @doc """
  The destination for `source` under `root`, for a target's `work`.

  The basename is `source`'s, unchanged apart from the same illegal-character sanitizing every
  other component gets: only the directories are Cinder's.
  """
  @spec book_dest(Work.t(), String.t(), String.t()) :: String.t()
  def book_dest(%Work{} = work, source, root),
    do: Path.join([root, author_folder(work), title_folder(work), file_name(source)])

  # `Path.basename/1` already drops any directory part, so a release-supplied `../../etc/passwd`
  # cannot survive as a path. It does NOT drop a bare `..`, and a dots-only name would become a
  # segment that climbs out of the library root, so the same `sanitize/1` runs on the basename
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
  # would reintroduce exactly what `sanitize/1` just removed. Anything that does not survive as a
  # plain alphanumeric suffix is dropped entirely — the file still imports, under a safe name.
  defp fallback_extension(basename) do
    case String.downcase(Path.extname(basename)) do
      "." <> rest = extension when rest != "" ->
        if String.match?(rest, ~r/\A[a-z0-9]+\z/u), do: extension, else: ""

      _no_usable_extension ->
        ""
    end
  end

  @doc "The folder name a work's author credits produce."
  @spec author_folder(Work.t()) :: String.t()
  def author_folder(%Work{} = work) do
    case sanitize(primary_author(work)) do
      "" -> @unknown_author
      name -> visible(name)
    end
  end

  @doc "The folder name a work's title produces."
  @spec title_folder(%{title: String.t()}) :: String.t()
  def title_folder(%{title: title}) do
    case sanitize(title) do
      "" -> "Untitled"
      folder -> visible(folder)
    end
  end

  # The same rule `file_name/1` applies to the basename, applied to the folders it sits under: a
  # component beginning with a dot is hidden, and Booklore/Calibre skip dot-directories while
  # walking the library. Reachable from ordinary catalog data, not just hostile input — `sanitize/1`
  # strips `/`, so the work `.hack//Legend of the Twilight` yields the folder
  # `.hackLegend of the Twilight`. The import would succeed, the target would arm `:available`,
  # and the book would be invisible with nothing reporting why.
  #
  # Prefixed rather than replaced: unlike a filename, a folder name is the only place the author
  # or title is recorded on disk, so it is worth keeping legible.
  #
  # #399: `Cinder.Library.Naming` has the identical hazard for movie/episode folders and the
  # identical fix — shared here rather than duplicated a second time.
  defdelegate visible(name), to: Naming

  # The lowest-positioned `author` credit — the contract's credits are ordered and role-bearing,
  # and a co-authored work has to land in ONE folder deterministically. Position ties break on the
  # author's own id so two runs cannot disagree. Non-author roles (translator, editor, narrator)
  # are never used: a translator's name on the folder would file the book under someone who did
  # not write it.
  defp primary_author(%Work{credits: credits}) when is_list(credits) do
    credits
    |> Enum.filter(&match?(%{role: "author", author: %{name: name}} when is_binary(name), &1))
    |> Enum.min_by(&{&1.position || 0, &1.author.id}, fn -> nil end)
    |> case do
      nil -> ""
      credit -> credit.author.name
    end
  end

  defp primary_author(%Work{}), do: ""

  # Byte-for-byte the rule `Cinder.Library.Naming` applies to a movie title: strip
  # filesystem-illegal characters, trim, and collapse a dots-only name to "" so it can never
  # become a `..` path segment that climbs out of the library root.
  #
  # Public (not private) and `@doc false`, matching `visible/1` just above: reused by
  # `Cinder.Library.AudiobookNaming` via `defdelegate` rather than reimplemented — the same
  # hostile-input class (`../../etc/passwd` release/work names, dot-leading folders) closed once
  # here, not twice.
  @doc false
  def sanitize(name) when is_binary(name) do
    name
    |> String.replace(@illegal, "")
    |> String.trim()
    |> reject_dot_only()
  end

  def sanitize(_name), do: ""

  @doc false
  def reject_dot_only(name), do: if(name =~ ~r/\A\.+\z/, do: "", else: name)
end
