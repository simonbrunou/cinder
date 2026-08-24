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

  test "a title made only of annotation words still resolves" do
    # Rejecting an empty folded title must not fold a real title away first. *Omnibus* and
    # *Book* are both real titles; `drop_article/1` already refuses to strip a lone article for
    # the same reason.
    for title <- ["Omnibus", "Book", "Audio"] do
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
