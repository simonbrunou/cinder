defmodule Cinder.Books.TitleFold do
  @moduledoc """
  The one title fold the books domain compares by.

  `Cinder.Books.Identity` (which work did the requester mean?) and
  `Cinder.Acquisition.BookScorer` (does this release name that work?) ask the same question of
  different strings, so they must fold identically. They did not: `BookScorer` was written by
  copying `Identity`'s private helpers and **left `lossy_fold?/1` behind**, which reopened exactly
  the bug `Identity` documents — "ノルウェイの森 1" and "海辺のカフカ 1" both fold to `["1"]`, so a
  release for one satisfied a request for the other with full confidence.

  That is the whole reason this module exists. A fold and its guard are one decision; keeping them
  in one place is what stops the next copy from dropping half of it again.
  """

  @articles ~w(the a an le la les el los der die das)

  @doc """
  Folds `string` to comparable tokens: NFD-decompose so "Misérables" matches "Miserables", drop
  apostrophes and every non-ASCII byte, then split on anything that is not a letter or digit.

  `nil` folds to `[]`.
  """
  @spec tokens(String.t() | nil) :: [String.t()]
  def tokens(nil), do: []

  def tokens(string) do
    string
    |> nfd()
    |> String.downcase()
    |> String.replace(~r/['’]/u, "")
    |> String.replace(~r/[^\x00-\x7f]/u, "")
    |> String.split(~r/[^a-z0-9]+/, trim: true)
  end

  @doc """
  Whether folding `string` would discard letters — i.e. whether the fold's answer can be trusted
  at all.

  Folding to ASCII *discards* non-Latin script rather than failing on it, so a title that is only
  partly non-ASCII keeps just its Latin residue and two unrelated works can share it.
  Volume-numbered manga and light novels are the realistic population. Combining marks are
  excluded because they are precisely what the fold is meant to drop: "Les Misérables" is not
  lossy, "Война и мир" is.

  A title we cannot fold is a title we cannot compare, so callers must refuse rather than guess.
  """
  @spec lossy?(String.t() | nil) :: boolean()
  def lossy?(nil), do: false

  def lossy?(string), do: string |> nfd() |> String.match?(~r/[^\x00-\x7f\x{0300}-\x{036F}]/u)

  @doc """
  Drops one leading article, so "The Little Prince" and Open Library's "Little Prince" compare
  equal. At most one, and never the only token.
  """
  @spec drop_article([String.t()]) :: [String.t()]
  def drop_article([article | rest]) when rest != [],
    do: if(article in @articles, do: rest, else: [article | rest])

  def drop_article(words), do: words

  # NFD first, and not only for the diacritic fold: the regexes above raise on malformed UTF-8, and
  # a garbled provider or indexer title must never raise out of a comparison called in a loop.
  # :unicode.characters_to_nfd_binary hands back the decodable prefix as {:error | :incomplete,
  # ok_part, rest}, which is the most of the input that can be matched on at all.
  defp nfd(string) do
    case :unicode.characters_to_nfd_binary(string) do
      binary when is_binary(binary) -> binary
      {_kind, ok_part, _rest} -> ok_part
    end
  end
end
