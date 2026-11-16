defmodule Cinder.Acquisition.EbooksTest do
  # What only the e-book kind decides: its query plan (the ISBNs of its e-book editions), the
  # release struct a search returns, the formats its scorer accepts, and the absence of a
  # selection function. `book_search_test.exs` runs what `Cinder.Acquisition.BookSearch` does for
  # every book kind, e-books included.
  use Cinder.DataCase, async: true

  import Mox

  alias Cinder.Acquisition.{EbookRelease, Ebooks}
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
      size: 2_000_000,
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
    expect(IndexerMock, :search_ebook, fn _author, _title, _opts -> {:ok, []} end)

    expect(IndexerMock, :search_ebook_query, count, fn query, _opts ->
      send(test_pid, {:query, query})
      {:ok, []}
    end)
  end

  describe "the e-book query plan" do
    test "probes an e-book edition's ISBN and not its ASIN" do
      work = persisted_work(:ebook, [{"asin", "B000EBOOK1"}, {"isbn", "9780060512750"}])
      expect_free_text_queries(2)

      assert {:ok, [], true} = Ebooks.search(work)
      assert ["9780060512750", "The Dispossessed Ursula K. Le Guin"] == received_queries(2)
    end

    test "an audiobook edition's ISBN is not probed for an e-book search" do
      work = persisted_work(:audiobook, [{"isbn", "9999999999999"}])
      expect_free_text_queries(1)

      assert {:ok, [], true} = Ebooks.search(work)
      assert ["The Dispossessed Ursula K. Le Guin"] == received_queries(1)
    end
  end

  describe "e-book releases" do
    test "parses each result into an EbookRelease" do
      expect(IndexerMock, :search_ebook, fn _author, _title, _opts ->
        {:ok, [indexer_result("Ursula K. Le Guin - The Dispossessed (epub) [retail]")]}
      end)

      expect(IndexerMock, :search_ebook_query, fn _query, _opts -> {:ok, []} end)

      assert {:ok, [%EbookRelease{} = release], true} = Ebooks.search(@work)
      assert release.formats == [:epub]
      assert release.retail? == true
    end

    test "candidates/2 accepts an epub and rejects a pdf and another author's book" do
      expect(IndexerMock, :search_ebook, fn _author, _title, _opts ->
        {:ok,
         [
           indexer_result("Ursula K. Le Guin - The Dispossessed (epub)"),
           indexer_result("Ursula K. Le Guin - The Dispossessed (pdf)"),
           indexer_result("Someone Else - A Different Book (epub)")
         ]}
      end)

      expect(IndexerMock, :search_ebook_query, fn _query, _opts -> {:ok, []} end)

      assert {:ok, %{accepted: accepted, rejected: rejected, complete?: true}} =
               Ebooks.candidates(@work)

      assert [{release, %{format: :epub}}] = accepted
      assert release.title == "Ursula K. Le Guin - The Dispossessed (epub)"

      assert Enum.sort(Enum.map(rejected, fn {_release, reason} -> reason end)) ==
               [:author_mismatch, :format_rejected]
    end
  end

  test "no automatic selection function is exported in this slice" do
    refute function_exported?(Ebooks, :best_book_release, 1)
    refute function_exported?(Ebooks, :best_book_release, 2)
  end
end
