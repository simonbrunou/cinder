defmodule Cinder.Books.IdentityTest do
  use ExUnit.Case, async: true

  import Mox

  alias Cinder.Books.{Identity, PrimaryMetadataMock, SecondaryMetadataMock}

  setup :verify_on_exit!

  setup do
    stub(PrimaryMetadataMock, :provider, fn -> :openlibrary end)
    stub(SecondaryMetadataMock, :provider, fn -> :hardcover end)
    :ok
  end

  test "a durable provider reference is fetched directly, never searched" do
    expect(PrimaryMetadataMock, :get_work, fn "OL50548W" -> {:ok, work("OL50548W")} end)

    assert {:ok, resolution} = Identity.resolve("openlibrary:work:OL50548W")
    assert resolution.provider == :openlibrary
    assert resolution.work.foreign_id == "OL50548W"
    assert resolution.evidence.strategy == :provider_reference
  end

  test "the secondary answers only when the primary had no reliable match" do
    expect(PrimaryMetadataMock, :search, fn _query ->
      {:ok, [candidate(:openlibrary, "Wrong Book", ["Someone Else"])]}
    end)

    expect(SecondaryMetadataMock, :search, fn _query ->
      {:ok, [candidate(:hardcover, "Beloved", ["Toni Morrison"])]}
    end)

    expect(SecondaryMetadataMock, :get_work, fn "id" -> {:ok, work("id")} end)

    assert {:ok, %{provider: :hardcover}} = Identity.resolve("Beloved Toni Morrison")
  end

  test "the primary wins outright, and the secondary is never called" do
    expect(PrimaryMetadataMock, :search, fn _query ->
      {:ok, [candidate(:openlibrary, "Beloved", ["Toni Morrison"])]}
    end)

    expect(PrimaryMetadataMock, :get_work, fn "id" -> {:ok, work("id")} end)

    assert {:ok, %{provider: :openlibrary}} = Identity.resolve("Beloved Toni Morrison")
  end

  test "a provider that errors is skipped, not treated as an answer" do
    expect(PrimaryMetadataMock, :search, fn _query -> {:error, :timeout} end)

    expect(SecondaryMetadataMock, :search, fn _query ->
      {:ok, [candidate(:hardcover, "Beloved", ["Toni Morrison"])]}
    end)

    expect(SecondaryMetadataMock, :get_work, fn "id" -> {:ok, work("id")} end)

    assert {:ok, %{provider: :hardcover}} = Identity.resolve("Beloved Toni Morrison")
  end

  test "every provider erroring is an outage, distinct from a searched-and-found-nothing" do
    expect(PrimaryMetadataMock, :search, fn _query -> {:error, :timeout} end)
    expect(SecondaryMetadataMock, :search, fn _query -> {:error, :not_configured} end)

    assert {:error, :providers_unavailable} = Identity.resolve("Beloved Toni Morrison")
  end

  test "providers that answered with nothing usable is unresolved, not an outage" do
    expect(PrimaryMetadataMock, :search, fn _query -> {:ok, []} end)

    expect(SecondaryMetadataMock, :search, fn _query ->
      {:ok, [candidate(:hardcover, "Beloved", ["Someone Else"])]}
    end)

    assert {:unresolved, :no_reliable_match} = Identity.resolve("Beloved Toni Morrison")
  end

  test "a title-only query resolves nothing, however good the title match" do
    expect(PrimaryMetadataMock, :search, fn _query ->
      {:ok, [candidate(:openlibrary, "Dune", ["Frank Herbert"])]}
    end)

    expect(SecondaryMetadataMock, :search, fn _query ->
      {:ok, [candidate(:hardcover, "Dune", ["Frank Herbert"])]}
    end)

    assert {:unresolved, :no_reliable_match} = Identity.resolve("Dune")
  end

  test "a wrong contributor in the query resolves nothing" do
    expect(PrimaryMetadataMock, :search, fn _query ->
      {:ok, [candidate(:openlibrary, "Dune", ["Frank Herbert"])]}
    end)

    expect(SecondaryMetadataMock, :search, fn _query -> {:ok, []} end)

    assert {:unresolved, :no_reliable_match} = Identity.resolve("Dune Brian Herbert")
  end

  test "a winning candidate whose work fetch then fails is an outage, not a half-built work" do
    expect(PrimaryMetadataMock, :search, fn _query ->
      {:ok, [candidate(:openlibrary, "Beloved", ["Toni Morrison"])]}
    end)

    expect(PrimaryMetadataMock, :get_work, fn "id" -> {:error, :timeout} end)

    assert {:error, :providers_unavailable} = Identity.resolve("Beloved Toni Morrison")
  end

  test "a reference naming an unconfigured provider falls through to search" do
    expect(PrimaryMetadataMock, :search, fn query ->
      assert query == "goodreads:work:123"
      {:ok, []}
    end)

    expect(SecondaryMetadataMock, :search, fn _query -> {:ok, []} end)

    assert {:unresolved, :no_reliable_match} = Identity.resolve("goodreads:work:123")
  end

  test "a malformed-UTF-8 query is rejected rather than raising out of the resolver" do
    expect(PrimaryMetadataMock, :search, fn _query ->
      {:ok, [candidate(:openlibrary, "Beloved", ["Toni Morrison"])]}
    end)

    expect(SecondaryMetadataMock, :search, fn _query -> {:ok, []} end)

    assert {:unresolved, :no_reliable_match} = Identity.resolve(<<"Belo", 0xFF, "ved">>)
  end

  test "the order a provider lists its contributors in does not decide the outcome" do
    # A work credited to both "Murakami" and "Haruki Murakami" resolved or not purely on which
    # came first: the short form consumed the surname the long one needed. A miss rather than a
    # wrong work on its own — but it knocks the correct candidate out while a wrong one is still
    # standing, which is how several of this module's wrong-work bugs reached the caller.
    for names <- [["Haruki Murakami", "Murakami"], ["Murakami", "Haruki Murakami"]] do
      expect(PrimaryMetadataMock, :search, fn _query ->
        {:ok, [candidate(:openlibrary, "Norwegian Wood", names)]}
      end)

      expect(PrimaryMetadataMock, :get_work, fn "id" -> {:ok, work("id")} end)

      assert {:ok, %{provider: :openlibrary}} =
               Identity.resolve("Norwegian Wood Haruki Murakami"),
             "order #{inspect(names)} should resolve"
    end
  end

  test "two contributors sharing a surname do not consume each other" do
    expect(PrimaryMetadataMock, :search, fn _query ->
      {:ok, [candidate(:openlibrary, "The Expanse", ["Daniel Abraham", "Ty Abraham"])]}
    end)

    expect(PrimaryMetadataMock, :get_work, fn "id" -> {:ok, work("id")} end)

    assert {:ok, %{provider: :openlibrary}} =
             Identity.resolve("The Expanse Daniel Abraham Ty Abraham")
  end

  test "name order does not decide identity" do
    expect(PrimaryMetadataMock, :search, fn _query ->
      {:ok, [candidate(:openlibrary, "The Three-Body Problem", ["Liu Cixin"])]}
    end)

    expect(PrimaryMetadataMock, :get_work, fn "id" -> {:ok, work("id")} end)

    assert {:ok, %{provider: :openlibrary}} = Identity.resolve("The Three-Body Problem Cixin Liu")
  end

  test "an author-only query resolves nothing, even when every title folds away" do
    # Folding strips non-ASCII, so a Japanese title folds to "" — and so does a query that named
    # only an author. Without the empty-key rejection these matched each other and the
    # edition-count tie-break silently returned the biggest: a first-result selection by another
    # name, on an input weaker than the bare title the contract already rejects.
    murakami = [
      %{candidate(:openlibrary, "ノルウェイの森", ["Haruki Murakami"]) | foreign_id: "OL1W"},
      %{
        candidate(:openlibrary, "海辺のカフカ", ["Haruki Murakami"])
        | foreign_id: "OL2W",
          edition_count: 12
      }
    ]

    expect(PrimaryMetadataMock, :search, fn _query -> {:ok, murakami} end)
    expect(SecondaryMetadataMock, :search, fn _query -> {:ok, []} end)

    assert {:unresolved, :no_reliable_match} = Identity.resolve("Haruki Murakami")
  end

  test "a query that is an author plus only format noise resolves nothing" do
    expect(PrimaryMetadataMock, :search, fn _query ->
      {:ok, [%{candidate(:openlibrary, "", ["Neil Gaiman"]) | foreign_id: "OL9W"}]}
    end)

    expect(SecondaryMetadataMock, :search, fn _query -> {:ok, []} end)

    assert {:unresolved, :no_reliable_match} = Identity.resolve("Neil Gaiman audiobook")
  end

  test "a common word in a title is not treated as a format annotation" do
    # "book" was in the noise list, to absorb "e-book" (which folds to two tokens). Stripping it
    # from both sides made "The Book Thief" and "The Thief" the same title, so a request for one
    # resolved confidently to the other — a wrong-work selection, not merely a missed match.
    expect(PrimaryMetadataMock, :search, fn _query ->
      {:ok, [candidate(:openlibrary, "The Thief", ["Markus Zusak"])]}
    end)

    expect(SecondaryMetadataMock, :search, fn _query -> {:ok, []} end)

    assert {:unresolved, :no_reliable_match} =
             Identity.resolve("The Book Thief Markus Zusak")
  end

  test "an annotation word inside a real title does not fold it into a different work" do
    # Stripping annotations from *both* sides made these pairs identical, so a request for one
    # resolved confidently to the other. Annotations now come off the query only, and only when
    # the provider's title does not itself carry the word.
    for {query, other_work} <- [
          {"The Audio Book A Author", "The Book"},
          {"First Edition A Author", "First"},
          {"An Abridged Life A Author", "A Life"}
        ] do
      expect(PrimaryMetadataMock, :search, fn _query ->
        {:ok, [candidate(:openlibrary, other_work, ["A Author"])]}
      end)

      expect(SecondaryMetadataMock, :search, fn _query -> {:ok, []} end)

      assert {:unresolved, :no_reliable_match} = Identity.resolve(query),
             "#{query} must not resolve to #{other_work}"
    end
  end

  test "the work the requester actually named outranks the annotation reading of it" do
    # "omnibus" is a real annotation — `lord-of-the-rings` in the corpus depends on it — so with
    # only "Reader" in front of it the matcher reads the query that way. But when the work the
    # requester named is also a candidate, exactness wins over edition count, by 99x here.
    named = %{candidate(:openlibrary, "Omnibus Reader", ["A Author"]) | foreign_id: "named"}

    other = %{
      candidate(:openlibrary, "Reader", ["A Author"])
      | foreign_id: "other",
        edition_count: 99
    }

    expect(PrimaryMetadataMock, :search, fn _query -> {:ok, [other, named]} end)
    expect(PrimaryMetadataMock, :get_work, fn "named" -> {:ok, work("named")} end)

    assert {:ok, %{provider: :openlibrary}} = Identity.resolve("Omnibus Reader A Author")
  end

  test "an annotation the provider's title does not carry is still stripped" do
    expect(PrimaryMetadataMock, :search, fn _query ->
      {:ok, [candidate(:openlibrary, "The Lord of the Rings", ["J. R. R. Tolkien"])]}
    end)

    expect(PrimaryMetadataMock, :get_work, fn "id" -> {:ok, work("id")} end)

    assert {:ok, %{provider: :openlibrary}} =
             Identity.resolve("The Lord of the Rings J. R. R. Tolkien omnibus")
  end

  test "an annotation word starting a title is not trimmed off the front of it" do
    # Trimming the leading edge made "Ebook Reader" resolve to a different work called "Reader" —
    # a leading annotation word is far likelier to be the title's own first word than a
    # requester's note, so only the trailing edge is trimmed.
    expect(PrimaryMetadataMock, :search, fn _query ->
      {:ok, [candidate(:openlibrary, "Reader", ["A Author"])]}
    end)

    expect(SecondaryMetadataMock, :search, fn _query -> {:ok, []} end)

    assert {:unresolved, :no_reliable_match} = Identity.resolve("Ebook Reader A Author")
  end

  test "a title that folds to its Latin residue is unresolved, not a coin flip" do
    # Folding discards non-Latin script instead of failing on it, so "ノルウェイの森 1" and
    # "海辺のカフカ 1" both key to "1" — and edition count handed back whichever was more popular,
    # with full confidence. The `title != ""` rule only catches a total loss; a partial one is no
    # more trustworthy. Volume-numbered manga and light-novel rows are the realistic population.
    norwegian = %{
      candidate(:openlibrary, "ノルウェイの森 1", ["Haruki Murakami"])
      | foreign_id: "norwegian",
        edition_count: 50
    }

    kafka = %{
      candidate(:openlibrary, "海辺のカフカ 1", ["Haruki Murakami"])
      | foreign_id: "kafka",
        edition_count: 3
    }

    expect(PrimaryMetadataMock, :search, fn _query -> {:ok, [norwegian, kafka]} end)
    expect(SecondaryMetadataMock, :search, fn _query -> {:ok, []} end)

    assert {:unresolved, :no_reliable_match} =
             Identity.resolve("海辺のカフカ 1 Haruki Murakami")
  end

  test "a diacritic is folded, not treated as a lossy script" do
    # The lossy-fold rejection must not swallow the accent handling it sits next to: combining
    # marks are exactly what the fold is meant to drop.
    for {title, author, query} <- [
          {"Les Misérables", "Victor Hugo", "Les Miserables Victor Hugo"},
          {"Cien años de soledad", "Gabriel García Márquez",
           "Cien anos de soledad Gabriel Garcia Marquez"}
        ] do
      expect(PrimaryMetadataMock, :search, fn _query ->
        {:ok, [candidate(:openlibrary, title, [author])]}
      end)

      expect(PrimaryMetadataMock, :get_work, fn "id" -> {:ok, work("id")} end)

      assert {:ok, %{provider: :openlibrary}} = Identity.resolve(query), "#{title} should resolve"
    end
  end

  test "an annotation word mid-title is part of the title, not an annotation" do
    # An annotation is something a requester appends or prepends. Stripping one from anywhere in
    # the query let "The Audiobook Murders" resolve to a different work called "The Murders" —
    # the same collision as "The Audio Book"/"The Book", surviving a narrower word list because
    # the mechanism, not the vocabulary, was the problem. Only the edges can hold an annotation.
    for {query, other_work} <- [
          {"The Audiobook Murders A Author", "The Murders"},
          {"An Ebook Primer A Author", "A Primer"},
          {"The Omnibus of Crime A Author", "Of Crime"}
        ] do
      expect(PrimaryMetadataMock, :search, fn _query ->
        {:ok, [candidate(:openlibrary, other_work, ["A Author"])]}
      end)

      expect(SecondaryMetadataMock, :search, fn _query -> {:ok, []} end)

      assert {:unresolved, :no_reliable_match} = Identity.resolve(query),
             "#{query} must not resolve to #{other_work}"
    end
  end

  test "a trailing annotation is still trimmed" do
    for query <- ["Dune Frank Herbert audiobook", "Dune Frank Herbert omnibus"] do
      expect(PrimaryMetadataMock, :search, fn _query ->
        {:ok, [candidate(:openlibrary, "Dune", ["Frank Herbert"])]}
      end)

      expect(PrimaryMetadataMock, :get_work, fn "id" -> {:ok, work("id")} end)

      assert {:ok, %{provider: :openlibrary}} = Identity.resolve(query), "#{query} should resolve"
    end
  end

  test "an article plus an annotation is not a title that matches everything" do
    # A prior revision stripped annotations from the title too, and guarded only against
    # stripping it to []. "The Omnibus" survived that guard as the bare article "the" — as did
    # "The Audio" and "The Edition" — so they all keyed alike and a query for one returned
    # another. Stripping the query side only removes the shared bucket entirely.
    expect(PrimaryMetadataMock, :search, fn _query ->
      {:ok, [candidate(:openlibrary, "The Audio", ["A Author"])]}
    end)

    expect(SecondaryMetadataMock, :search, fn _query -> {:ok, []} end)

    assert {:unresolved, :no_reliable_match} = Identity.resolve("The Omnibus A Author")
  end

  test "a title made only of annotation words still resolves" do
    # Rejecting an empty folded title must not fold a real title away first. *Omnibus* and
    # *Book* are both real titles; `drop_article/1` already refuses to strip a lone article for
    # the same reason.
    for title <- ["Omnibus", "Book", "Audio", "Audiobook"] do
      expect(PrimaryMetadataMock, :search, fn _query ->
        {:ok, [candidate(:openlibrary, title, ["A Author"])]}
      end)

      expect(PrimaryMetadataMock, :get_work, fn "id" -> {:ok, work("id")} end)

      assert {:ok, %{provider: :openlibrary}} = Identity.resolve("#{title} A Author"),
             "#{title} should resolve"
    end
  end

  defp candidate(provider, title, contributors) do
    %{
      provider: provider,
      foreign_id: "id",
      title: title,
      contributors: Enum.map(contributors, &%{foreign_id: &1, name: &1, role: "author"}),
      contributors_incomplete: false,
      first_published_year: nil,
      edition_count: 1
    }
  end

  defp work(foreign_id) do
    %{
      provider: :openlibrary,
      foreign_id: foreign_id,
      title: "Beloved",
      first_published_on: nil,
      overview: nil,
      contributors: [],
      contributors_incomplete: true,
      editions: [],
      series: []
    }
  end
end
