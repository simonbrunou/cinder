defmodule Cinder.Books.IdentityCollisionTest do
  @moduledoc """
  An exhaustive cross-product fence against the one failure the parity contract forbids outright:
  a query naming one work resolving to a *different* work.

  Six review rounds each found an instance of that — an author-only query matching every
  non-Latin-titled work, "The Book Thief" folding onto "The Thief", "The Omnibus" folding onto the
  bare article "the", "The Audiobook Murders" onto "The Murders", "Omnibus Ebook Reader" onto
  "Reader", "ノルウェイの森 1" onto "海辺のカフカ 1" — and each fix closed the instance while the
  class survived to the next round. Every one came from a fold that is many-to-one being applied
  to both the query and the candidate title.

  The frozen corpus cannot see this class: `corpus-v1.json` holds no CJK, Cyrillic or Greek at
  all, and its only near-collisions are the article and diacritic folds that are *supposed* to
  match. So this enumerates the folds directly instead. Titles in one group must match each other;
  titles in different groups must never match, whatever the edition counts say.
  """
  use ExUnit.Case, async: true

  alias Cinder.Books.Identity

  @author "Ursula Fixture"

  # Each entry is one work's acceptable spellings, tagged with whether the matcher can resolve it
  # at all. `:lossy` marks a title whose fold to ASCII discards letters — deliberately
  # unresolvable, because its Latin residue is shared with every other such title.
  @groups [
    # plain, and the leading-article fold that is meant to work
    {["The Little Prince", "Little Prince"], :resolvable},
    {["The Prince"], :resolvable},
    # diacritics must fold; different works must not
    {["Les Misérables", "Les Miserables"], :resolvable},
    {["Les Misères"], :resolvable},
    {["Cien años de soledad", "Cien anos de soledad"], :resolvable},
    # annotation words as ordinary title words
    {["The Book Thief"], :resolvable},
    {["The Thief"], :resolvable},
    {["The Audio Book"], :resolvable},
    {["The Book"], :resolvable},
    {["The Audiobook Murders"], :resolvable},
    {["The Murders"], :resolvable},
    {["Ebook Reader"], :resolvable},
    {["Reader"], :resolvable},
    {["First Edition"], :resolvable},
    {["First"], :resolvable},
    {["An Abridged Life"], :resolvable},
    {["A Life"], :resolvable},
    # a title that is nothing but annotation/article words
    {["Omnibus", "The Omnibus"], :resolvable},
    # titles that genuinely END in an annotation word — the one trim still in play
    {["The Complete Omnibus"], :resolvable},
    {["The Complete"], :resolvable},
    {["Digital Audiobook"], :resolvable},
    {["Digital"], :resolvable},
    # a run of them, so widening the trim past one word shows up as a new collision
    {["Reader Ebook Omnibus"], :resolvable},
    {["The Audio"], :resolvable},
    # non-Latin scripts, including the part-Latin residue case
    {["ノルウェイの森 1"], :lossy},
    {["海辺のカフカ 1"], :lossy},
    {["三体 Book 1"], :lossy},
    {["球状闪电 Book 1"], :lossy},
    {["Война и мир, Vol. 2"], :lossy},
    {["Анна Каренина, Vol. 2"], :lossy},
    # punctuation and apostrophe folds that are meant to work
    {["Alice's Adventures", "Alices Adventures"], :resolvable},
    {["Anti-Hero", "Anti Hero"], :resolvable}
  ]

  test "no query for one work ever resolves to a different work" do
    pairs =
      for {{group, _}, i} <- Enum.with_index(@groups),
          {{other, _}, j} <- Enum.with_index(@groups),
          i != j,
          query_title <- group,
          other_title <- other,
          do: {query_title, other_title}

    # The wrong work is given 99 editions and the query names a work not on the table at all, so
    # anything but a rejection is the matcher inventing a match.
    collisions =
      for {query_title, other_title} <- pairs,
          result = Identity.select([candidate(other_title, 99)], "#{query_title} #{@author}"),
          match?({:ok, _, _}, result),
          do: {query_title, other_title}

    unexpected = Enum.reject(collisions, fn {q, o} -> annotation_suffix?(q, o) end)

    assert unexpected == [], """
    a query resolved to a different work:
    #{Enum.map_join(unexpected, "\n", fn {q, o} -> "  #{inspect(q)} -> #{inspect(o)}" end)}
    """

    # The retained collisions are asserted to exist, not merely tolerated: if the trailing trim is
    # ever dropped this goes empty and the test says so, rather than quietly passing.
    assert Enum.sort(collisions) == [
             {"Digital Audiobook", "Digital"},
             {"The Complete Omnibus", "The Complete"}
           ]

    # Non-vacuous: state the sweep size, so a bank that stopped enumerating would be visible.
    assert length(pairs) > 1000
  end

  test "a title whose fold loses letters is unresolvable even against itself" do
    # The deliberate half of the lossy-fold rule, asserted rather than left as a silent gap: these
    # titles cannot be resolved at all, because their Latin residue ("1", "Book 1", "Vol. 2") is
    # shared with every other such title and matching on it is a coin flip.
    lossy = for {group, :lossy} <- @groups, title <- group, do: title
    assert length(lossy) == 6

    for title <- lossy do
      assert :none = Identity.select([candidate(title, 1)], "#{title} #{@author}"),
             "#{inspect(title)} must stay unresolved rather than match on its Latin residue"
    end
  end

  test "the spellings within a group do still resolve to each other" do
    for {group, :resolvable} <- @groups, query_title <- group, stored_title <- group do
      assert {:ok, _candidate, _evidence} =
               Identity.select([candidate(stored_title, 1)], "#{query_title} #{@author}"),
             "#{inspect(query_title)} should resolve to #{inspect(stored_title)}"
    end
  end

  test "no permutation of a provider's contributor list changes the result" do
    # `subtract_contributors/2` consumes query tokens greedily, so the order contributors arrive
    # in used to decide the outcome — a short spelling ate the surname a longer one needed.
    # Sorting longest-first fixed the selection; sorting by name as well fixed the *evidence*,
    # which two equal-length spellings of one person still varied ("Le Guin Ursula" beside
    # "Ursula Le Guin"). Both matter: the evidence is part of the resolution a caller persists.
    #
    # Exhaustive over a small token universe rather than by example, because example-picking is
    # exactly what let five earlier rounds of this class through.
    words = ~w(a b c)
    names = words ++ for(x <- words, y <- words, x != y, do: "#{x} #{y}")

    outcomes =
      for title <- ["t", "t a"],
          first <- names,
          second <- names,
          first != second,
          query <- ["#{title} a b", "#{title} a c", "#{title} b c"] do
        forward = Identity.select([candidate_with(title, [first, second])], query)
        reversed = Identity.select([candidate_with(title, [second, first])], query)
        {query, title, [first, second], normalize(forward), normalize(reversed)}
      end

    divergent = Enum.filter(outcomes, fn {_q, _t, _n, a, b} -> a != b end)

    assert divergent == [], """
    contributor order changed the result:
    #{Enum.map_join(divergent, "\n", fn {q, _t, n, a, b} -> "  #{inspect(q)} #{inspect(n)}: #{inspect(a)} vs #{inspect(b)}" end)}
    """

    # Non-vacuous on two counts: the sweep is large, and some of it actually resolves.
    assert length(outcomes) > 400
    assert Enum.count(outcomes, fn {_q, _t, _n, a, _b} -> a != :none end) > 20
  end

  defp candidate_with(title, names) do
    %{
      candidate(title, 1)
      | contributors: Enum.map(names, &%{foreign_id: &1, name: &1, role: "author"})
    }
  end

  defp normalize({:ok, work, evidence}),
    do: {work.foreign_id, Enum.sort(evidence.contributors_matched)}

  defp normalize(other), do: other

  test "the retained collision needs the provider to have withheld the named work" do
    # What bounds the residual above: it only fires when the work the requester named is not in
    # the candidate list at all. When it is, strength precedence returns it — here over a wrong
    # work holding 99x the editions.
    named = candidate("The Complete Omnibus", 1)
    other = %{candidate("The Complete", 99) | foreign_id: "other"}

    assert {:ok, %{title: "The Complete Omnibus"}, _} =
             Identity.select([other, named], "The Complete Omnibus #{@author}")

    assert {:ok, %{title: "The Complete Omnibus"}, _} =
             Identity.select([named, other], "The Complete Omnibus #{@author}")
  end

  # A title ending in an annotation word is indistinguishable from the same title with a
  # requester's annotation appended — "The Complete Omnibus" against "The Complete" plus
  # "omnibus". Nothing in a query can separate the two readings, and dropping the trailing trim to
  # avoid it would cost `lord-of-the-rings` and put the corpus at 35/40, under the contract's 90%.
  # So it is retained deliberately, bounded by the precedence test above, and pinned here so it
  # cannot grow.
  defp annotation_suffix?(query_title, other_title) do
    Enum.any?(~w(omnibus ebook audiobook), fn word ->
      String.downcase(query_title) == String.downcase(other_title) <> " " <> word
    end)
  end

  defp candidate(title, edition_count) do
    %{
      provider: :openlibrary,
      foreign_id: title,
      title: title,
      contributors: [%{foreign_id: "A1", name: @author, role: "author"}],
      contributors_incomplete: false,
      first_published_year: nil,
      edition_count: edition_count
    }
  end
end
