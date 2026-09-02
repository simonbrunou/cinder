defmodule Cinder.Acquisition.AudiobooksTest do
  use Cinder.DataCase, async: true

  import Mox

  alias Cinder.Acquisition.Audiobooks
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

  defp indexer_result(title, attrs \\ %{}) do
    Map.merge(
      %{
        title: title,
        size: 100_000_000,
        download_url: "http://indexer.test/#{:erlang.phash2(title)}",
        protocol: :torrent,
        query_origins: [:free_text]
      },
      attrs
    )
  end

  describe "query planning" do
    test "searches structured author+title, then bounded free text" do
      test_pid = self()

      expect(IndexerMock, :search_audiobook, fn author, title, _opts ->
        send(test_pid, {:structured, author, title})
        {:ok, []}
      end)

      expect(IndexerMock, :search_audiobook_query, fn query, _opts ->
        send(test_pid, {:free_text, query})
        {:ok, []}
      end)

      assert {:ok, [], true} = Audiobooks.search(@work)

      assert_received {:structured, "Ursula K. Le Guin", "The Dispossessed"}
      assert_received {:free_text, "The Dispossessed Ursula K. Le Guin"}
    end

    test "probes each identifier before the structured and free-text queries" do
      test_pid = self()
      work = Map.put(@work, :identifiers, ["B000FC0SIM", "9780060512750"])

      expect(IndexerMock, :search_audiobook_query, 3, fn query, _opts ->
        send(test_pid, {:query, query})
        {:ok, []}
      end)

      expect(IndexerMock, :search_audiobook, fn _author, _title, _opts -> {:ok, []} end)

      assert {:ok, [], true} = Audiobooks.search(work)

      assert [
               "B000FC0SIM",
               "9780060512750",
               "The Dispossessed Ursula K. Le Guin"
             ] == received_queries(3)
    end

    test "caps identifier probes so a work with many editions cannot fan out" do
      test_pid = self()
      work = Map.put(@work, :identifiers, Enum.map(1..40, &"B000FC0#{&1}"))

      # 3 identifier probes + 1 free text = 4 search_audiobook_query calls, plus 1 structured.
      expect(IndexerMock, :search_audiobook_query, 4, fn query, _opts ->
        send(test_pid, {:query, query})
        {:ok, []}
      end)

      expect(IndexerMock, :search_audiobook, fn _author, _title, _opts -> {:ok, []} end)

      assert {:ok, [], true} = Audiobooks.search(work)

      # The plan never exceeds what max_queries/0 advertises, and that number is the real bound.
      assert Audiobooks.max_queries() == 5
    end

    test "a work with no author still searches by title" do
      test_pid = self()

      expect(IndexerMock, :search_audiobook, fn author, title, _opts ->
        send(test_pid, {:structured, author, title})
        {:ok, []}
      end)

      expect(IndexerMock, :search_audiobook_query, fn query, _opts ->
        send(test_pid, {:free_text, query})
        {:ok, []}
      end)

      assert {:ok, [], true} = Audiobooks.search(%{title: "Beowulf", authors: []})

      assert_received {:structured, nil, "Beowulf"}
      assert_received {:free_text, "Beowulf"}
    end
  end

  describe "result aggregation" do
    test "dedupes by download_url and merges query provenance" do
      shared = indexer_result("Ursula K. Le Guin - The Dispossessed (M4B)")

      expect(IndexerMock, :search_audiobook, fn _author, _title, _opts ->
        {:ok, [%{shared | query_origins: [:id_scoped]}]}
      end)

      expect(IndexerMock, :search_audiobook_query, fn _query, _opts ->
        {:ok, [%{shared | query_origins: [:free_text]}]}
      end)

      assert {:ok, [release], true} = Audiobooks.search(@work)
      assert Enum.sort(release.query_origins) == [:free_text, :id_scoped]
    end

    test "parses each result into an AudiobookRelease" do
      expect(IndexerMock, :search_audiobook, fn _author, _title, _opts ->
        {:ok,
         [indexer_result("Ursula K. Le Guin - The Dispossessed (M4B) (Narrated by Jane Doe)")]}
      end)

      expect(IndexerMock, :search_audiobook_query, fn _query, _opts -> {:ok, []} end)

      assert {:ok, [release], true} = Audiobooks.search(@work)
      assert release.formats == [:m4b]
      assert release.narrator == "Jane Doe"
    end
  end

  describe "partial failure" do
    test "one failing query yields complete? false, not an error" do
      expect(IndexerMock, :search_audiobook, fn _author, _title, _opts ->
        {:error, :timeout}
      end)

      expect(IndexerMock, :search_audiobook_query, fn _query, _opts ->
        {:ok, [indexer_result("Ursula K. Le Guin - The Dispossessed (M4B)")]}
      end)

      assert {:ok, [_release], false} = Audiobooks.search(@work)
    end

    test "every query failing is an error, so an outage is never read as an absence" do
      expect(IndexerMock, :search_audiobook, fn _author, _title, _opts -> {:error, :timeout} end)
      expect(IndexerMock, :search_audiobook_query, fn _query, _opts -> {:error, :timeout} end)

      assert {:error, :indexer_unavailable} = Audiobooks.search(@work)
    end
  end

  describe "candidates/2" do
    test "returns ranked acceptances and explained rejections" do
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

    test "propagates an indexer outage" do
      expect(IndexerMock, :search_audiobook, fn _author, _title, _opts -> {:error, :timeout} end)
      expect(IndexerMock, :search_audiobook_query, fn _query, _opts -> {:error, :timeout} end)

      assert {:error, :indexer_unavailable} = Audiobooks.candidates(@work)
    end
  end

  describe "loaded works" do
    test "derives title, authors, and ASIN-before-ISBN from a persisted work" do
      test_pid = self()

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
          media_kind: :audiobook,
          title: "The Dispossessed",
          identifier: %{provider: "openlibrary", kind: "edition", foreign_id: "OL1M"}
        })

      {:ok, _isbn} =
        Cinder.Books.put_identifier(edition, %{
          provider: "isbn",
          kind: "edition",
          foreign_id: "9780060512750"
        })

      {:ok, _asin} =
        Cinder.Books.put_identifier(edition, %{
          provider: "asin",
          kind: "edition",
          foreign_id: "B000FC0SIM"
        })

      loaded = Cinder.Books.get_work(work.id)

      expect(IndexerMock, :search_audiobook, fn author, title, _opts ->
        send(test_pid, {:structured, author, title})
        {:ok, []}
      end)

      expect(IndexerMock, :search_audiobook_query, 3, fn query, _opts ->
        send(test_pid, {:query, query})
        {:ok, []}
      end)

      assert {:ok, [], true} = Audiobooks.search(loaded)

      # ASIN before ISBN — the audiobook sibling of `Books`' ISBN-13-before-ISBN-10 ordering.
      assert_received {:query, "B000FC0SIM"}
      assert_received {:query, "9780060512750"}
      assert_received {:structured, "Ursula K. Le Guin", "The Dispossessed"}
    end

    test "an e-book edition's identifiers are not probed for an audiobook search" do
      test_pid = self()

      {:ok, work} =
        Cinder.Books.upsert_work(%{
          title: "Beloved",
          contributors_incomplete: false,
          identifier: %{provider: "openlibrary", kind: "work", foreign_id: "OL50548W"}
        })

      {:ok, edition} =
        Cinder.Books.upsert_edition(%{
          work_id: work.id,
          media_kind: :ebook,
          title: "Beloved",
          identifier: %{provider: "openlibrary", kind: "edition", foreign_id: "OL2M"}
        })

      {:ok, _asin} =
        Cinder.Books.put_identifier(edition, %{
          provider: "asin",
          kind: "edition",
          foreign_id: "B0EBOOKASIN"
        })

      loaded = Cinder.Books.get_work(work.id)

      expect(IndexerMock, :search_audiobook, fn _author, _title, _opts -> {:ok, []} end)

      expect(IndexerMock, :search_audiobook_query, fn query, _opts ->
        send(test_pid, {:query, query})
        {:ok, []}
      end)

      assert {:ok, [], true} = Audiobooks.search(loaded)

      refute_received {:query, "B0EBOOKASIN"}
    end

    test "a translator credit does not satisfy the author gate" do
      {:ok, translator} =
        Cinder.Books.upsert_author(%{
          name: "Gregory Rabassa",
          identifier: %{provider: "openlibrary", kind: "author", foreign_id: "OL233456A"}
        })

      {:ok, work} =
        Cinder.Books.upsert_work(%{
          title: "Hopscotch",
          contributors_incomplete: false,
          identifier: %{provider: "openlibrary", kind: "work", foreign_id: "OL99999W"}
        })

      {:ok, _credit} =
        Cinder.Books.put_credit(work, %{author_id: translator.id, role: "translator"})

      loaded = Cinder.Books.get_work(work.id)

      translator_named = %{
        title: "Gregory Rabassa - Hopscotch (M4B)",
        size: 100_000_000,
        download_url: "http://indexer.test/9",
        protocol: :torrent
      }

      expect(IndexerMock, :search_audiobook, fn _author, _title, _opts ->
        {:ok, [translator_named]}
      end)

      expect(IndexerMock, :search_audiobook_query, fn _query, _opts -> {:ok, []} end)

      assert {:ok, %{accepted: [], rejected: [{_release, :author_mismatch}]}} =
               Audiobooks.candidates(loaded)
    end

    test "a persisted work's series membership reaches the scorer" do
      {:ok, author} =
        Cinder.Books.upsert_author(%{
          name: "Brandon Sanderson",
          identifier: %{provider: "openlibrary", kind: "author", foreign_id: "OL1394861A"}
        })

      {:ok, work} =
        Cinder.Books.upsert_work(%{
          title: "The Way of Kings",
          contributors_incomplete: false,
          identifier: %{provider: "openlibrary", kind: "work", foreign_id: "OL15358691W"}
        })

      {:ok, _credit} = Cinder.Books.put_credit(work, %{author_id: author.id, role: "author"})

      {:ok, _membership} =
        Cinder.Books.put_series_membership(work, %{
          name: "The Stormlight Archive",
          position: "1",
          provider: "openlibrary"
        })

      loaded = Cinder.Books.get_work(work.id)

      series_named = %{
        title: "Brandon Sanderson - The Stormlight Archive 01 - The Way of Kings (M4B)",
        size: 100_000_000,
        download_url: "http://indexer.test/1",
        protocol: :torrent
      }

      expect(IndexerMock, :search_audiobook, fn _author, _title, _opts ->
        {:ok, [series_named]}
      end)

      expect(IndexerMock, :search_audiobook_query, fn _query, _opts -> {:ok, []} end)

      assert {:ok, %{accepted: [{accepted, _evidence}], rejected: []}} =
               Audiobooks.candidates(loaded)

      assert accepted.title == series_named.title
    end
  end

  test "no automatic selection function is exported in this slice" do
    refute function_exported?(Audiobooks, :best_audiobook_release, 1)
    refute function_exported?(Audiobooks, :best_audiobook_release, 2)
  end
end
