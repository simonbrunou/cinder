defmodule Cinder.Acquisition.BooksTest do
  use Cinder.DataCase, async: true

  import Mox

  alias Cinder.Acquisition.Books
  alias Cinder.Acquisition.IndexerMock

  setup :verify_on_exit!

  @work %{title: "The Dispossessed", authors: ["Ursula K. Le Guin"]}

  defp indexer_result(title, attrs \\ %{}) do
    Map.merge(
      %{
        title: title,
        size: 2_000_000,
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

      expect(IndexerMock, :search_book, fn author, title, _opts ->
        send(test_pid, {:structured, author, title})
        {:ok, []}
      end)

      expect(IndexerMock, :search_book_query, fn query, _opts ->
        send(test_pid, {:free_text, query})
        {:ok, []}
      end)

      assert {:ok, [], true} = Books.search(@work)

      assert_received {:structured, "Ursula K. Le Guin", "The Dispossessed"}
      assert_received {:free_text, "The Dispossessed Ursula K. Le Guin"}
    end

    test "probes each ISBN before the structured and free-text queries" do
      test_pid = self()
      work = Map.put(@work, :isbns, ["9780060512750", "0060512750"])

      expect(IndexerMock, :search_book_query, 3, fn query, _opts ->
        send(test_pid, {:query, query})
        {:ok, []}
      end)

      expect(IndexerMock, :search_book, fn _author, _title, _opts -> {:ok, []} end)

      assert {:ok, [], true} = Books.search(work)

      assert_received {:query, "9780060512750"}
      assert_received {:query, "0060512750"}
      assert_received {:query, "The Dispossessed Ursula K. Le Guin"}
    end

    test "caps ISBN probes so a work with many editions cannot fan out" do
      test_pid = self()
      work = Map.put(@work, :isbns, Enum.map(1..40, &"978000000#{&1}"))

      # 3 ISBN probes + 1 free text = 4 search_book_query calls, plus 1 structured — never 40.
      expect(IndexerMock, :search_book_query, 4, fn query, _opts ->
        send(test_pid, {:query, query})
        {:ok, []}
      end)

      expect(IndexerMock, :search_book, fn _author, _title, _opts -> {:ok, []} end)

      assert {:ok, [], true} = Books.search(work)

      # The plan never exceeds what max_queries/0 advertises, and that number is the real bound.
      assert Books.max_queries() == 5
    end

    test "a work with no author still searches by title" do
      test_pid = self()

      expect(IndexerMock, :search_book, fn author, title, _opts ->
        send(test_pid, {:structured, author, title})
        {:ok, []}
      end)

      expect(IndexerMock, :search_book_query, fn query, _opts ->
        send(test_pid, {:free_text, query})
        {:ok, []}
      end)

      assert {:ok, [], true} = Books.search(%{title: "Beowulf", authors: []})

      assert_received {:structured, nil, "Beowulf"}
      assert_received {:free_text, "Beowulf"}
    end
  end

  describe "result aggregation" do
    test "dedupes by download_url and merges query provenance" do
      shared = indexer_result("Ursula K. Le Guin - The Dispossessed (epub)")

      expect(IndexerMock, :search_book, fn _author, _title, _opts ->
        {:ok, [%{shared | query_origins: [:id_scoped]}]}
      end)

      expect(IndexerMock, :search_book_query, fn _query, _opts ->
        {:ok, [%{shared | query_origins: [:free_text]}]}
      end)

      assert {:ok, [release], true} = Books.search(@work)
      assert Enum.sort(release.query_origins) == [:free_text, :id_scoped]
    end

    test "parses each result into a BookRelease" do
      expect(IndexerMock, :search_book, fn _author, _title, _opts ->
        {:ok, [indexer_result("Ursula K. Le Guin - The Dispossessed (epub) [retail]")]}
      end)

      expect(IndexerMock, :search_book_query, fn _query, _opts -> {:ok, []} end)

      assert {:ok, [release], true} = Books.search(@work)
      assert release.formats == [:epub]
      assert release.retail? == true
    end
  end

  describe "partial failure" do
    test "one failing query yields complete? false, not an error" do
      expect(IndexerMock, :search_book, fn _author, _title, _opts ->
        {:error, :timeout}
      end)

      expect(IndexerMock, :search_book_query, fn _query, _opts ->
        {:ok, [indexer_result("Ursula K. Le Guin - The Dispossessed (epub)")]}
      end)

      assert {:ok, [_release], false} = Books.search(@work)
    end

    test "every query failing is an error, so an outage is never read as an absence" do
      expect(IndexerMock, :search_book, fn _author, _title, _opts -> {:error, :timeout} end)
      expect(IndexerMock, :search_book_query, fn _query, _opts -> {:error, :timeout} end)

      assert {:error, :indexer_unavailable} = Books.search(@work)
    end
  end

  describe "candidates/2" do
    test "returns ranked acceptances and explained rejections" do
      expect(IndexerMock, :search_book, fn _author, _title, _opts ->
        {:ok,
         [
           indexer_result("Ursula K. Le Guin - The Dispossessed (epub)"),
           indexer_result("Ursula K. Le Guin - The Dispossessed (pdf)"),
           indexer_result("Someone Else - A Different Book (epub)")
         ]}
      end)

      expect(IndexerMock, :search_book_query, fn _query, _opts -> {:ok, []} end)

      assert {:ok, %{accepted: accepted, rejected: rejected, complete?: true}} =
               Books.candidates(@work)

      assert [{release, %{format: :epub}}] = accepted
      assert release.title == "Ursula K. Le Guin - The Dispossessed (epub)"

      assert Enum.sort(Enum.map(rejected, fn {_release, reason} -> reason end)) ==
               [:author_mismatch, :format_rejected]
    end

    test "propagates an indexer outage" do
      expect(IndexerMock, :search_book, fn _author, _title, _opts -> {:error, :timeout} end)
      expect(IndexerMock, :search_book_query, fn _query, _opts -> {:error, :timeout} end)

      assert {:error, :indexer_unavailable} = Books.candidates(@work)
    end
  end

  describe "loaded works" do
    test "derives title, authors, and e-book ISBNs from a persisted work" do
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
          media_kind: :ebook,
          title: "The Dispossessed",
          identifier: %{provider: "openlibrary", kind: "edition", foreign_id: "OL1M"}
        })

      {:ok, _isbn} =
        Cinder.Books.put_identifier(edition, %{
          provider: "isbn",
          kind: "edition",
          foreign_id: "9780060512750"
        })

      loaded = Cinder.Books.get_work(work.id)

      expect(IndexerMock, :search_book, fn author, title, _opts ->
        send(test_pid, {:structured, author, title})
        {:ok, []}
      end)

      expect(IndexerMock, :search_book_query, 2, fn query, _opts ->
        send(test_pid, {:query, query})
        {:ok, []}
      end)

      assert {:ok, [], true} = Books.search(loaded)

      assert_received {:query, "9780060512750"}
      assert_received {:structured, "Ursula K. Le Guin", "The Dispossessed"}
    end

    test "an audiobook edition's ISBN is not probed for an e-book search" do
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
          media_kind: :audiobook,
          title: "Beloved",
          identifier: %{provider: "openlibrary", kind: "edition", foreign_id: "OL2M"}
        })

      {:ok, _isbn} =
        Cinder.Books.put_identifier(edition, %{
          provider: "isbn",
          kind: "edition",
          foreign_id: "9999999999999"
        })

      loaded = Cinder.Books.get_work(work.id)

      expect(IndexerMock, :search_book, fn _author, _title, _opts -> {:ok, []} end)

      expect(IndexerMock, :search_book_query, fn query, _opts ->
        send(test_pid, {:query, query})
        {:ok, []}
      end)

      assert {:ok, [], true} = Books.search(loaded)

      refute_received {:query, "9999999999999"}
    end

    test "a persisted work's series membership reaches the scorer" do
      # candidates/2 is the whole point of carrying series through normalize/1: without it the
      # scorer's series allowance is dead code in production, because only hand-built maps in
      # tests ever supplied a :series key.
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
        title: "Brandon Sanderson - The Stormlight Archive 01 - The Way of Kings (epub)",
        size: 2_000_000,
        download_url: "http://indexer.test/1",
        protocol: :torrent
      }

      expect(IndexerMock, :search_book, fn _author, _title, _opts -> {:ok, [series_named]} end)
      expect(IndexerMock, :search_book_query, fn _query, _opts -> {:ok, []} end)

      assert {:ok, %{accepted: [{accepted, _evidence}], rejected: []}} = Books.candidates(loaded)
      assert accepted.title == series_named.title
    end
  end

  test "no automatic selection function is exported in this slice" do
    refute function_exported?(Books, :best_book_release, 1)
    refute function_exported?(Books, :best_book_release, 2)
  end
end
