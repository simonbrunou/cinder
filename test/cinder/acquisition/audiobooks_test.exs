defmodule Cinder.Acquisition.AudiobooksTest do
  # What only the audiobook kind decides: its query plan (the ASINs, then the ISBNs, of its
  # audiobook editions), the release struct a search returns, the formats its scorer accepts, and
  # the absence of a selection function. `book_search_test.exs` runs what
  # `Cinder.Acquisition.BookSearch` does for every book kind, audiobooks included.
  use Cinder.DataCase, async: true

  import Mox

  alias Cinder.Acquisition.{AudiobookRelease, Audiobooks}
  alias Cinder.Acquisition.IndexerMock

  setup :verify_on_exit!

  # Drains `count` {:query, _} messages in arrival order. `assert_received` matches selectively,
  # so it cannot witness ordering; receiving a bare pattern in sequence can.
  defp received_queries(count) do
    Enum.map(1..count, fn _index ->
      receive do
        {:query, query} -> query
      after
        0 -> flunk("expected #{count} queries")
      end
    end)
  end

  @work %{title: "The Dispossessed", authors: ["Ursula K. Le Guin"]}

  defp indexer_result(title) do
    %{
      title: title,
      size: 100_000_000,
      download_url: "http://indexer.test/#{:erlang.phash2(title)}",
      protocol: :torrent,
      query_origins: [:free_text]
    }
  end

  # A work credited to Ursula K. Le Guin whose one edition of `media_kind` carries `identifiers`
  # ({provider, value}) in the given order.
  defp persisted_work(media_kind, identifiers) do
    {:ok, author} =
      Cinder.Books.upsert_author(%{
        name: "Ursula K. Le Guin",
        identifier: %{provider: "openlibrary", kind: "author", foreign_id: "OL26320A"}
      })

    {:ok, work} =
      Cinder.Books.upsert_work(%{
        title: "The Dispossessed",
        contributors_incomplete: false,
        identifier: %{provider: "openlibrary", kind: "work", foreign_id: "OL8193420W"}
      })

    {:ok, _credit} = Cinder.Books.put_credit(work, %{author_id: author.id, role: "author"})

    {:ok, edition} =
      Cinder.Books.upsert_edition(%{
        work_id: work.id,
        media_kind: media_kind,
        title: "The Dispossessed",
        identifier: %{provider: "openlibrary", kind: "edition", foreign_id: "OL1M"}
      })

    for {provider, value} <- identifiers do
      {:ok, _identifier} =
        Cinder.Books.put_identifier(edition, %{
          provider: provider,
          kind: "edition",
          foreign_id: value
        })
    end

    Cinder.Books.get_work(work.id)
  end

  # Expects the structured query once and `count` free-text queries, each reported in order.
  defp expect_free_text_queries(count) do
    test_pid = self()
    expect(IndexerMock, :search_audiobook, fn _author, _title, _opts -> {:ok, []} end)

    expect(IndexerMock, :search_audiobook_query, count, fn query, _opts ->
      send(test_pid, {:query, query})
      {:ok, []}
    end)
  end

  describe "the audiobook query plan" do
    # The ISBN is inserted first, so only the plan's provider order puts the ASIN ahead of it.
    test "probes an audiobook edition's ASIN, then its ISBN" do
      work = persisted_work(:audiobook, [{"isbn", "9780060512750"}, {"asin", "B000FC0SIM"}])
      expect_free_text_queries(3)

      assert {:ok, [], true} = Audiobooks.search(work)

      assert ["B000FC0SIM", "9780060512750", "The Dispossessed Ursula K. Le Guin"] ==
               received_queries(3)
    end

    test "an e-book edition's identifiers are not probed for an audiobook search" do
      work = persisted_work(:ebook, [{"asin", "B0EBOOKASIN"}, {"isbn", "9780060512750"}])
      expect_free_text_queries(1)

      assert {:ok, [], true} = Audiobooks.search(work)
      assert ["The Dispossessed Ursula K. Le Guin"] == received_queries(1)
    end
  end

  describe "audiobook releases" do
    test "parses each result into an AudiobookRelease" do
      expect(IndexerMock, :search_audiobook, fn _author, _title, _opts ->
        {:ok,
         [indexer_result("Ursula K. Le Guin - The Dispossessed (M4B) (Narrated by Jane Doe)")]}
      end)

      expect(IndexerMock, :search_audiobook_query, fn _query, _opts -> {:ok, []} end)

      assert {:ok, [%AudiobookRelease{} = release], true} = Audiobooks.search(@work)
      assert release.formats == [:m4b]
      assert release.narrator == "Jane Doe"
    end

    test "candidates/2 accepts an M4B and rejects an epub and another author's book" do
      expect(IndexerMock, :search_audiobook, fn _author, _title, _opts ->
        {:ok,
         [
           indexer_result("Ursula K. Le Guin - The Dispossessed (M4B)"),
           indexer_result("Ursula K. Le Guin - The Dispossessed (epub)"),
           indexer_result("Someone Else - A Different Book (M4B)")
         ]}
      end)

      expect(IndexerMock, :search_audiobook_query, fn _query, _opts -> {:ok, []} end)

      assert {:ok, %{accepted: accepted, rejected: rejected, complete?: true}} =
               Audiobooks.candidates(@work)

      assert [{release, %{format: :m4b}}] = accepted
      assert release.title == "Ursula K. Le Guin - The Dispossessed (M4B)"

      assert Enum.sort(Enum.map(rejected, fn {_release, reason} -> reason end)) ==
               [:author_mismatch, :format_rejected]
    end
  end

  test "no automatic selection function is exported in this slice" do
    refute function_exported?(Audiobooks, :best_audiobook_release, 1)
    refute function_exported?(Audiobooks, :best_audiobook_release, 2)
  end
end
