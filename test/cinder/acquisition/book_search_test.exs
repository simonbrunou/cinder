defmodule Cinder.Acquisition.BookSearchTest do
  # Everything `Cinder.Acquisition.BookSearch` does for any book kind's query plan, run once per
  # kind through that kind's public module: the order and cap of the queries, how results merge
  # and failures count, and how a persisted work, a plain map or a NormalizedWork is read.
  # `ebooks_test.exs` and `audiobooks_test.exs` cover what each kind's own plan and release struct
  # decide.
  use Cinder.DataCase,
    async: true,
    parameterize: [%{kind: :ebook}, %{kind: :audiobook}]

  import Mox

  alias Cinder.Acquisition.{Audiobooks, Ebooks, IndexerMock}
  alias Cinder.Acquisition.BookSearch.NormalizedWork

  setup :verify_on_exit!

  # Per kind: the public search module, its two indexer callbacks, the key a plain-map work carries
  # its identifiers under, one identifier of the kind's preferred provider, and a release format
  # and size the kind's scorer accepts.
  @kinds %{
    ebook: %{
      search: Ebooks,
      structured: :search_ebook,
      text: :search_ebook_query,
      identifiers_key: :isbns,
      provider: "isbn",
      identifier: "9780060512750",
      formats: "epub",
      size: 2_000_000
    },
    audiobook: %{
      search: Audiobooks,
      structured: :search_audiobook,
      text: :search_audiobook_query,
      identifiers_key: :identifiers,
      provider: "asin",
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

  # As expect_queries/2, but the structured query reports too, as `{:structured, author, title}`,
  # so `received_queries/1` shows where it falls among the free-text queries.
  defp expect_all_queries(kind, text_count) do
    test_pid = self()

    expect(IndexerMock, @kinds[kind].structured, fn author, title, _opts ->
      send(test_pid, {:query, {:structured, author, title}})
      {:ok, []}
    end)

    expect(IndexerMock, @kinds[kind].text, text_count, fn query, _opts ->
      send(test_pid, {:query, query})
      {:ok, []}
    end)
  end

  # One indexer result for `kind`, in a format its scorer accepts.
  defp indexer_result(kind, name, attrs \\ %{}) do
    title = "#{name} (#{@kinds[kind].formats})"

    Map.merge(
      %{
        title: title,
        size: @kinds[kind].size,
        download_url: "http://indexer.test/#{:erlang.phash2(title)}",
        protocol: :torrent,
        query_origins: [:free_text]
      },
      attrs
    )
  end

  defp persisted_work(title, foreign_id, author \\ {"Ursula K. Le Guin", "OL26320A", "author"}) do
    {name, author_id, role} = author

    {:ok, author} =
      Cinder.Books.upsert_author(%{
        name: name,
        identifier: %{provider: "openlibrary", kind: "author", foreign_id: author_id}
      })

    {:ok, work} =
      Cinder.Books.upsert_work(%{
        title: title,
        contributors_incomplete: false,
        identifier: %{provider: "openlibrary", kind: "work", foreign_id: foreign_id}
      })

    {:ok, _credit} = Cinder.Books.put_credit(work, %{author_id: author.id, role: role})
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

  describe "the queries one search issues" do
    test "probes each identifier in the order given, then searches author and title, then free text",
         %{kind: kind} do
      work =
        Map.put(@work, @kinds[kind].identifiers_key, [@kinds[kind].identifier, "9780000000017"])

      expect_all_queries(kind, 3)

      assert {:ok, [], true} = @kinds[kind].search.search(work)

      assert [
               @kinds[kind].identifier,
               "9780000000017",
               {:structured, "Ursula K. Le Guin", "The Dispossessed"},
               @free_text
             ] == received_queries(4)
    end

    test "a work with no author still searches by title", %{kind: kind} do
      expect_all_queries(kind, 1)

      assert {:ok, [], true} = @kinds[kind].search.search(%{title: "Beowulf", authors: []})
      assert [{:structured, nil, "Beowulf"}, "Beowulf"] == received_queries(2)
    end

    # A work with forty editions must not fan out into forty indexer requests. Mox counts every
    # call, so the search issues exactly max_queries/0 queries: three identifier probes, the
    # structured query and free text.
    test "caps identifier probes so the search issues at most max_queries/0 queries",
         %{kind: kind} do
      identifiers = Enum.map(1..40, &"978000000#{&1}")
      work = Map.put(@work, @kinds[kind].identifiers_key, identifiers)

      expect_all_queries(kind, 4)

      assert {:ok, [], true} = @kinds[kind].search.search(work)
      assert 5 == @kinds[kind].search.max_queries()

      assert Enum.take(identifiers, 3) ++
               [{:structured, "Ursula K. Le Guin", "The Dispossessed"}, @free_text] ==
               received_queries(@kinds[kind].search.max_queries())
    end
  end

  describe "results" do
    test "dedupes by download_url and merges query provenance", %{kind: kind} do
      shared = indexer_result(kind, "Ursula K. Le Guin - The Dispossessed")

      expect(IndexerMock, @kinds[kind].structured, fn _author, _title, _opts ->
        {:ok, [%{shared | query_origins: [:id_scoped]}]}
      end)

      expect(IndexerMock, @kinds[kind].text, fn _query, _opts ->
        {:ok, [%{shared | query_origins: [:free_text]}]}
      end)

      assert {:ok, [release], true} = @kinds[kind].search.search(@work)
      assert Enum.sort(release.query_origins) == [:free_text, :id_scoped]
    end

    # #1644: one link stays one book release, and it names the indexer of its first copy.
    test "one link from two indexers keeps the first copy's provenance", %{kind: kind} do
      shared = indexer_result(kind, "Ursula K. Le Guin - The Dispossessed")

      expect(IndexerMock, @kinds[kind].structured, fn _author, _title, _opts ->
        {:ok,
         [
           Map.merge(shared, %{
             query_origins: [:id_scoped],
             indexer_id: 1,
             indexer_source: "native",
             indexer_name: "One",
             download_url_origin: "https://one.example",
             credentials_version: 3
           })
         ]}
      end)

      expect(IndexerMock, @kinds[kind].text, fn _query, _opts ->
        {:ok,
         [
           Map.merge(shared, %{
             query_origins: [:free_text],
             indexer_id: 2,
             indexer_source: "prowlarr",
             indexer_name: "Two",
             download_url_origin: "https://two.example",
             credentials_version: 8
           })
         ]}
      end)

      assert {:ok, [release], true} = @kinds[kind].search.search(@work)

      assert {release.indexer_id, release.indexer_source, release.indexer_name,
              release.download_url_origin, release.credentials_version} ==
               {1, "native", "One", "https://one.example", 3}

      assert Enum.sort(release.query_origins) == [:free_text, :id_scoped]
    end
  end

  describe "failures" do
    test "one failing query yields complete? false, not an error", %{kind: kind} do
      expect(IndexerMock, @kinds[kind].structured, fn _author, _title, _opts ->
        {:error, :timeout}
      end)

      expect(IndexerMock, @kinds[kind].text, fn _query, _opts ->
        {:ok, [indexer_result(kind, "Ursula K. Le Guin - The Dispossessed")]}
      end)

      assert {:ok, [_release], false} = @kinds[kind].search.search(@work)
    end

    test "candidates/2 reports a failing query as complete? false", %{kind: kind} do
      expect(IndexerMock, @kinds[kind].structured, fn _author, _title, _opts ->
        {:error, :timeout}
      end)

      expect(IndexerMock, @kinds[kind].text, fn _query, _opts ->
        {:ok, [indexer_result(kind, "Ursula K. Le Guin - The Dispossessed")]}
      end)

      assert {:ok, %{accepted: [_accepted], rejected: [], complete?: false}} =
               @kinds[kind].search.candidates(@work)
    end

    test "every query failing is an error, so an outage is never read as an absence",
         %{kind: kind} do
      expect(IndexerMock, @kinds[kind].structured, fn _author, _title, _opts ->
        {:error, :timeout}
      end)

      expect(IndexerMock, @kinds[kind].text, fn _query, _opts -> {:error, :timeout} end)

      assert @kinds[kind].search.search(@work) == {:error, :timeout}
    end

    test "candidates/2 propagates an indexer outage", %{kind: kind} do
      expect(IndexerMock, @kinds[kind].structured, fn _author, _title, _opts ->
        {:error, :timeout}
      end)

      expect(IndexerMock, @kinds[kind].text, fn _query, _opts -> {:error, :timeout} end)

      assert @kinds[kind].search.candidates(@work) == {:error, :timeout}
    end
  end

  describe "candidates/2 probes the work's identifiers" do
    test "for a persisted work", %{kind: kind} do
      work = persisted_work("The Dispossessed", "OL8193420W")

      put_edition(work, kind, "OL1M", ~D[2001-01-01], [
        {@kinds[kind].provider, @kinds[kind].identifier}
      ])

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
    # neither insert order nor its reverse. The audiobook row checks that one provider runs across
    # every edition before the next: both ASINs come before the newer edition's ISBN-13, and the
    # cap drops its ISBN-10, the fourth identifier. That expectation needs the audiobook plan's
    # ASIN-before-ISBN priority too, so this row also fails when the priority flips; the audiobooks
    # suite pins that priority on its own, on one edition.
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

    # Sorting by row id meant a work whose newest edition was imported first lost it to older
    # printings. An undated edition sorts last even when it was inserted last, because a missing
    # date is not evidence of recency.
    test "probes an undated edition after every dated one", %{kind: kind} do
      work = persisted_work("Beloved", "OL50548W")
      provider = @kinds[kind].provider

      for {foreign_id, date, value} <- [
            {"OL10M", ~D[1987-09-01], "#{provider}-1987"},
            {"OL20M", ~D[2019-03-01], "#{provider}-2019"},
            {"OL30M", nil, "#{provider}-undated"}
          ] do
        put_edition(work, kind, foreign_id, date, [{provider, value}])
      end

      expect_queries(kind, 4)

      assert {:ok, [], true} = @kinds[kind].search.search(Cinder.Books.get_work(work.id))

      assert [
               "#{provider}-2019",
               "#{provider}-1987",
               "#{provider}-undated",
               "Beloved Ursula K. Le Guin"
             ] ==
               received_queries(4)
    end
  end

  describe "a persisted work" do
    # Promoting every credit made "anyone named on the book" an author, and a translator's name
    # appears on many unrelated works, so it is not identity evidence for THIS one.
    test "a translator credit does not satisfy the author gate", %{kind: kind} do
      work =
        persisted_work("Hopscotch", "OL99999W", {"Gregory Rabassa", "OL233456A", "translator"})

      translator_named = indexer_result(kind, "Gregory Rabassa - Hopscotch")

      expect(IndexerMock, @kinds[kind].structured, fn _author, _title, _opts ->
        {:ok, [translator_named]}
      end)

      expect(IndexerMock, @kinds[kind].text, fn _query, _opts -> {:ok, []} end)

      assert {:ok, %{accepted: [], rejected: [{_release, :author_mismatch}]}} =
               @kinds[kind].search.candidates(Cinder.Books.get_work(work.id))
    end

    # BookSearch's normalize/2 reads a persisted work's series memberships into the
    # NormalizedWork. Without that the scorer's series allowance is dead code in production,
    # because only hand-built maps in tests ever supplied a :series key.
    test "its series membership reaches the scorer", %{kind: kind} do
      work =
        persisted_work(
          "The Way of Kings",
          "OL15358691W",
          {"Brandon Sanderson", "OL1394861A", "author"}
        )

      {:ok, _membership} =
        Cinder.Books.put_series_membership(work, %{
          name: "The Stormlight Archive",
          position: "1",
          provider: "openlibrary"
        })

      series_named =
        indexer_result(kind, "Brandon Sanderson - The Stormlight Archive 01 - The Way of Kings")

      expect(IndexerMock, @kinds[kind].structured, fn _author, _title, _opts ->
        {:ok, [series_named]}
      end)

      expect(IndexerMock, @kinds[kind].text, fn _query, _opts -> {:ok, []} end)

      assert {:ok, %{accepted: [{accepted, _evidence}], rejected: []}} =
               @kinds[kind].search.candidates(Cinder.Books.get_work(work.id))

      assert accepted.title == series_named.title
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
