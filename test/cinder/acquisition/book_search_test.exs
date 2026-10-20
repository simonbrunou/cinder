defmodule Cinder.Acquisition.BookSearchTest do
  # The search shared by the book family, run once per book kind through that kind's public module.
  # `books_test.exs` and `audiobooks_test.exs` cover each kind's plan; this file covers what both
  # plans rely on and neither file reaches: `candidates/2` probing a work's identifiers, and the
  # probe order across several editions.
  use Cinder.DataCase,
    async: true,
    parameterize: [%{kind: :ebook}, %{kind: :audiobook}]

  import Mox

  alias Cinder.Acquisition.{Audiobooks, Books, IndexerMock}

  setup :verify_on_exit!

  # Per kind: the public search module, its two indexer callbacks, the key a plain-map work carries
  # its identifiers under, and one identifier of the kind's preferred provider.
  @kinds %{
    ebook: %{
      search: Books,
      structured: :search_book,
      text: :search_book_query,
      identifiers_key: :isbns,
      identifier: "9780060512750"
    },
    audiobook: %{
      search: Audiobooks,
      structured: :search_audiobook,
      text: :search_audiobook_query,
      identifiers_key: :identifiers,
      identifier: "B000FC0SIM"
    }
  }

  @work %{title: "The Dispossessed", authors: ["Ursula K. Le Guin"]}
  @free_text "The Dispossessed Ursula K. Le Guin"

  # Drains `count` {:query, _} messages in arrival order, so a test can witness query ORDER.
  defp received_queries(count) do
    Enum.map(1..count, fn _index ->
      receive do
        {:query, query} -> query
      after
        0 -> flunk("expected #{count} queries")
      end
    end)
  end

  # Expects the structured query once and `text_count` free-text queries, each reported in order.
  defp expect_queries(kind, text_count) do
    test_pid = self()
    expect(IndexerMock, @kinds[kind].structured, fn _author, _title, _opts -> {:ok, []} end)

    expect(IndexerMock, @kinds[kind].text, text_count, fn query, _opts ->
      send(test_pid, {:query, query})
      {:ok, []}
    end)
  end

  defp persisted_work(title, foreign_id) do
    {:ok, author} =
      Cinder.Books.upsert_author(%{
        name: "Ursula K. Le Guin",
        identifier: %{provider: "openlibrary", kind: "author", foreign_id: "OL26320A"}
      })

    {:ok, work} =
      Cinder.Books.upsert_work(%{
        title: title,
        contributors_incomplete: false,
        identifier: %{provider: "openlibrary", kind: "work", foreign_id: foreign_id}
      })

    {:ok, _credit} = Cinder.Books.put_credit(work, %{author_id: author.id, role: "author"})
    work
  end

  # One edition of `kind`, with `identifiers` ({provider, value}) attached in the given order.
  defp put_edition(work, kind, foreign_id, release_date, identifiers) do
    {:ok, edition} =
      Cinder.Books.upsert_edition(%{
        work_id: work.id,
        media_kind: kind,
        title: work.title,
        release_date: release_date,
        identifier: %{provider: "openlibrary", kind: "edition", foreign_id: foreign_id}
      })

    for {provider, value} <- identifiers do
      {:ok, _identifier} =
        Cinder.Books.put_identifier(edition, %{
          provider: provider,
          kind: "edition",
          foreign_id: value
        })
    end
  end

  describe "candidates/2 probes the work's identifiers" do
    test "for a persisted work", %{kind: kind} do
      work = persisted_work("The Dispossessed", "OL8193420W")
      provider = if kind == :ebook, do: "isbn", else: "asin"
      put_edition(work, kind, "OL1M", ~D[2001-01-01], [{provider, @kinds[kind].identifier}])

      expect_queries(kind, 2)

      assert {:ok, %{accepted: [], rejected: [], complete?: true}} =
               @kinds[kind].search.candidates(Cinder.Books.get_work(work.id))

      assert [@kinds[kind].identifier, @free_text] == received_queries(2)
    end

    test "for a plain-map work", %{kind: kind} do
      work = Map.put(@work, @kinds[kind].identifiers_key, [@kinds[kind].identifier])

      expect_queries(kind, 2)

      assert {:ok, %{accepted: [], rejected: [], complete?: true}} =
               @kinds[kind].search.candidates(work)

      assert [@kinds[kind].identifier, @free_text] == received_queries(2)
    end
  end

  describe "probe order across editions" do
    # Each provider is probed across every edition of the kind (newest first) before the plan's
    # next provider, and an edition's ISBN-13 comes before its ISBN-10. Both rows insert the
    # ISBN-10 before the ISBN-13. The e-book row checks edition order: its editions' dates follow
    # neither insert order nor its reverse. The audiobook row checks provider order: both ASINs
    # come before the newer edition's ISBN-13, and the cap drops its ISBN-10, the fourth
    # identifier.
    test "orders probes by the plan's providers, then newest edition, then ISBN-13 before ISBN-10",
         %{kind: kind} do
      work = persisted_work("The Dispossessed", "OL8193420W")

      # {foreign_id, release_date, identifiers}, inserted in list order.
      {editions, expected} =
        case kind do
          :ebook ->
            {[
               {"OL1M", ~D[2010-01-01], [{"isbn", "9780000000024"}]},
               {"OL2M", ~D[2019-01-01], [{"isbn", "0060512750"}, {"isbn", "9780060512750"}]},
               {"OL3M", ~D[1999-01-01], [{"isbn", "9780000000017"}]}
             ], ["9780060512750", "0060512750", "9780000000024"]}

          :audiobook ->
            {[
               {"OL1M", ~D[1999-01-01], [{"asin", "B000OLDER1"}]},
               {"OL2M", ~D[2019-01-01],
                [{"isbn", "0060512750"}, {"isbn", "9780060512750"}, {"asin", "B000NEWER1"}]}
             ], ["B000NEWER1", "B000OLDER1", "9780060512750"]}
        end

      for {foreign_id, date, identifiers} <- editions do
        put_edition(work, kind, foreign_id, date, identifiers)
      end

      expect_queries(kind, 4)

      assert {:ok, [], true} = @kinds[kind].search.search(Cinder.Books.get_work(work.id))
      assert expected == Enum.take(received_queries(4), 3)
    end
  end
end
