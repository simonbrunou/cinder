defmodule Cinder.Library.BookFolders do
  @moduledoc """
  The `Author/Title` folders every book lands under, e-book or audiobook.

  `Cinder.Library.EbookNaming` puts an e-book's file in them and
  `Cinder.Library.AudiobookNaming` puts an audiobook's tracks in them. Folder names come from a
  work's credits and title only, so nothing here depends on the kind of book.

  Pure functions: no filesystem, no config, no Repo. `Cinder.Library.PathPolicy` still vets every
  path built from these folders before anything is written.
  """
  alias Cinder.Books.Work
  alias Cinder.Library.Naming

  @illegal ~r/[\/\\:*?"<>|]/
  @unknown_author "Unknown Author"

  # `Naming.visible/1` applies to these folders the rule `EbookNaming.file_name/1` applies to an
  # e-book's basename: a component beginning with a dot is hidden, and library scanners such as
  # Booklore's and Calibre's skip dot-directories while walking the library. Reachable from
  # ordinary catalog data, not just hostile input — `sanitize/1` strips `/`, so the work
  # `.hack//Legend of the Twilight` yields the folder `.hackLegend of the Twilight`. The import
  # would succeed, the target would arm `:available`, and the book would be invisible with nothing
  # reporting why.
  #
  # Prefixed rather than replaced, unlike an e-book's basename: the folders are where the author
  # and title are recorded on disk, so they are worth keeping legible.
  #
  # #399: `Cinder.Library.Naming` has the identical hazard for movie/episode folders and the
  # identical fix — shared from there rather than duplicated a second time.
  @doc "The folder name a work's author credits produce."
  @spec author_folder(Work.t()) :: String.t()
  def author_folder(%Work{} = work) do
    case sanitize(primary_author(work)) do
      "" -> @unknown_author
      name -> Naming.visible(name)
    end
  end

  @doc "The folder name a work's title produces."
  @spec title_folder(%{title: String.t()}) :: String.t()
  def title_folder(%{title: title}) do
    case sanitize(title) do
      "" -> "Untitled"
      folder -> Naming.visible(folder)
    end
  end

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
  # Public (not private) and `@doc false`: `EbookNaming.file_name/1` runs the same rule on an
  # e-book's basename, so the rule is written once, here.
  @doc false
  def sanitize(name) when is_binary(name) do
    name
    |> String.replace(@illegal, "")
    |> String.trim()
    |> reject_dot_only()
  end

  def sanitize(_name), do: ""

  defp reject_dot_only(name), do: if(name =~ ~r/\A\.+\z/, do: "", else: name)
end
