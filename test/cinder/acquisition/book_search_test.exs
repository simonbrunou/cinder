defmodule Cinder.Acquisition.BookSearchTest do
  # The search shared by the book family, run once per book kind through that kind's public module.
  # `books_test.exs` and `audiobooks_test.exs` cover each kind's plan; this file covers what both
  # plans rely on and neither file reaches: `candidates/2` probing a work's identifiers, the probe
  # order across several editions, and a work that is already normalized.
  use Cinder.DataCase,
    async: true,
    parameterize: [%{kind: :ebook}, %{kind: :audiobook}]

  import Mox

  alias Cinder.Acquisition.{Audiobooks, Ebooks, IndexerMock}
  alias Cinder.Acquisition.BookSearch.NormalizedWork

  setup :verify_on_exit!

  # Per kind: the public search module, its two indexer callbacks, the key a plain-map work carries
  # its identifiers under, and one identifier of the kind's preferred provider.
  @kinds %{
    ebook: %{
      search: Ebooks,
      structured: :search_ebook,
      text: :search_ebook_query,
      identifiers_key: :isbns,
      identifier: "9780060512750",
      formats: "epub",
      size: 2_000_000
    },
    audiobook: %{
      search: Audiobooks,
      structured: :search_audiobook,
      text: :search_audiobook_query,
      identifiers_key: :identifiers,
      identifier: "B000FC0SIM",
      formats: "m4b",
      size: 100_000_000
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

  # A NormalizedWork carries its identifiers under `identifiers` whatever the plan's
  # `identifiers_key` is, and normalizing it again must return it as it is. Read as a plain map,
  # the e-book plan would look under `:isbns` and probe nothing.
  describe "a normalized work" do
    test "defaults each list to []", %{kind: _kind} do
      assert %NormalizedWork{title: "The Dispossessed", authors: [], identifiers: [], series: []} ==
               %NormalizedWork{title: "The Dispossessed"}
    end

    test "search/1 runs the identifier probes it carries", %{kind: kind} do
      work = %NormalizedWork{
        title: "The Dispossessed",
        authors: ["Ursula K. Le Guin"],
        identifiers: [@kinds[kind].identifier, "9780000000017"]
      }

      expect_queries(kind, 3)

      assert {:ok, [], true} = @kinds[kind].search.search(work)
      assert [@kinds[kind].identifier, "9780000000017", @free_text] == received_queries(3)
    end

    test "candidates/1 probes its identifiers and scores releases against it", %{kind: kind} do
      work = %NormalizedWork{
        title: "The Way of Kings",
        authors: ["Brandon Sanderson"],
        identifiers: [@kinds[kind].identifier],
        series: ["The Stormlight Archive"]
      }

      # Only the series in the work lets "The Stormlight Archive 01" pass the title check.
      accepted =
        "Brandon Sanderson - The Stormlight Archive 01 - The Way of Kings (#{@kinds[kind].formats})"

      rejected =
        "Brandon Sanderson - The Stormlight Archive 02 - Words of Radiance " <>
          "(#{@kinds[kind].formats})"

      test_pid = self()
      expect(IndexerMock, @kinds[kind].structured, fn _author, _title, _opts -> {:ok, []} end)

      expect(IndexerMock, @kinds[kind].text, 2, fn query, _opts ->
        send(test_pid, {:query, query})

        {:ok,
         for title <- [accepted, rejected] do
           %{
             title: title,
             size: @kinds[kind].size,
             download_url: "http://indexer.test/#{:erlang.phash2({query, title})}",
             protocol: :torrent
           }
         end}
      end)

      assert {:ok, %{accepted: accepted_list, rejected: rejected_list, complete?: true}} =
               @kinds[kind].search.candidates(work)

      assert [@kinds[kind].identifier, "The Way of Kings Brandon Sanderson"] ==
               received_queries(2)

      assert [accepted, accepted] == Enum.map(accepted_list, fn {release, _} -> release.title end)

      assert [{rejected, :title_mismatch}, {rejected, :title_mismatch}] ==
               Enum.map(rejected_list, fn {release, reason} -> {release.title, reason} end)
    end
  end
end
