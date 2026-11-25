defmodule Cinder.Acquisition.BookSearchReportTest do
  # The book seam call sites and how a book search combines its queries' answers
  # (`Cinder.Acquisition.IndexerSource.Report.combine/1`), run once per kind through that kind's
  # public module. Every query goes to `PassedIndexerMock`, passed as `indexer_source:`, while the
  # env names `IndexerMock` with no stub: a query that reads the env instead of the opt fails with
  # `Mox.UnexpectedCallError`. The work has no identifiers, so a search sends two queries: the
  # structured one, then the free-text one.
  use Cinder.DataCase,
    async: true,
    parameterize: [%{kind: :ebook}, %{kind: :audiobook}]

  import Mox

  alias Cinder.Acquisition.{Audiobooks, Ebooks, PassedIndexerMock}
  alias Cinder.Acquisition.IndexerSource.Report

  setup :verify_on_exit!

  @kinds %{
    ebook: %{
      search: Ebooks,
      structured: :search_ebook,
      text: :search_ebook_query,
      formats: "epub",
      size: 2_000_000
    },
    audiobook: %{
      search: Audiobooks,
      structured: :search_audiobook,
      text: :search_audiobook_query,
      formats: "m4b",
      size: 100_000_000
    }
  }

  @work %{title: "The Dispossessed", authors: ["Ursula K. Le Guin"]}
  @opts [indexer_source: PassedIndexerMock]
  @until ~U[2030-01-01 00:00:00Z]
  @later ~U[2030-01-02 00:00:00Z]

  defp result(kind, url) do
    %{
      title: "Ursula K. Le Guin - The Dispossessed (#{@kinds[kind].formats})",
      size: @kinds[kind].size,
      download_url: "http://indexer.test/#{url}",
      protocol: :torrent,
      query_origins: [:free_text]
    }
  end

  defp report(id, outcome \\ {:failed, :timeout}),
    do: Report.put(Report.new(), {"native", id}, "Indexer #{id}", outcome)

  # The structured query answers `structured`, the free-text one `text`.
  defp answer(kind, structured, text) do
    expect(PassedIndexerMock, @kinds[kind].structured, fn "Ursula K. Le Guin",
                                                          "The Dispossessed",
                                                          [] ->
      structured
    end)

    expect(PassedIndexerMock, @kinds[kind].text, fn "The Dispossessed Ursula K. Le Guin", [] ->
      text
    end)
  end

  defp candidates(kind), do: @kinds[kind].search.candidates(@work, @opts)

  defp accepted_urls(%{accepted: accepted}),
    do: Enum.map(accepted, fn {release, _evidence} -> release.download_url end)

  describe "the seam call sites" do
    test "candidates judges the structured query's rows and carries its report", %{kind: kind} do
      answer(kind, {:ok, [result(kind, "structured")], report(1)}, {:ok, []})

      assert {:ok, %{complete?: false} = found} = candidates(kind)
      assert accepted_urls(found) == ["http://indexer.test/structured"]
      assert found.report == report(1)
    end

    test "candidates judges the text query's rows and carries its report", %{kind: kind} do
      answer(kind, {:ok, []}, {:ok, [result(kind, "text")], report(2)})

      assert {:ok, %{complete?: false} = found} = candidates(kind)
      assert accepted_urls(found) == ["http://indexer.test/text"]
      assert found.report == report(2)
    end

    test "search keeps its shape and sends every query to the source the opt names",
         %{kind: kind} do
      answer(kind, {:ok, [result(kind, "structured")], report(3)}, {:ok, []})

      assert {:ok, [release], false} = @kinds[kind].search.search(@work, @opts)
      assert release.download_url == "http://indexer.test/structured"
    end
  end

  describe "combining the queries' answers" do
    test "one query answering and one backing off is a complete answer", %{kind: kind} do
      answer(kind, {:ok, [result(kind, "a")]}, {:error, {:indexers_backing_off, @until}})

      assert {:ok, %{complete?: true, report: report}} = candidates(kind)
      assert report == Report.new()
    end

    test "one answering and one with no indexer answering is incomplete and lists its indexers",
         %{kind: kind} do
      answer(kind, {:ok, [result(kind, "a")]}, {:error, {:no_indexer_answered, report(4)}})

      assert {:ok, %{complete?: false, report: found}} = candidates(kind)
      assert found.indexers == report(4).indexers
      assert found.failed_calls == 1
    end

    test "every query backing off gives the backoff that ends first", %{kind: kind} do
      answer(
        kind,
        {:error, {:indexers_backing_off, @later}},
        {:error, {:indexers_backing_off, @until}}
      )

      assert candidates(kind) == {:error, {:indexers_backing_off, @until}}
    end

    test "a backoff and a timeout give the timeout", %{kind: kind} do
      answer(kind, {:error, {:indexers_backing_off, @until}}, {:error, :timeout})

      assert candidates(kind) == {:error, :timeout}
    end

    test "a backoff and :no_indexers give the backoff", %{kind: kind} do
      answer(kind, {:error, :no_indexers}, {:error, {:indexers_backing_off, @until}})

      assert candidates(kind) == {:error, {:indexers_backing_off, @until}}
    end

    test "only :no_indexers gives :no_indexers", %{kind: kind} do
      answer(kind, {:error, :no_indexers}, {:error, :no_indexers})

      assert candidates(kind) == {:error, :no_indexers}
    end

    test "two with no indexer answering give one error with both reports merged",
         %{kind: kind} do
      answer(
        kind,
        {:error, {:no_indexer_answered, report(5)}},
        {:error, {:no_indexer_answered, report(6, {:failed, :dns})}}
      )

      assert {:error, {:no_indexer_answered, found}} = candidates(kind)

      assert found.indexers == %{
               {"native", 5} => %{name: "Indexer 5", outcome: {:failed, :timeout}},
               {"native", 6} => %{name: "Indexer 6", outcome: {:failed, :dns}}
             }
    end

    test "merges the answers' reports in query order, the earlier reason winning a tie",
         %{kind: kind} do
      answer(
        kind,
        {:ok, [], report(7, {:failed, :timeout})},
        {:ok, [], report(7, {:failed, :dns})}
      )

      assert {:ok, %{report: found}} = candidates(kind)
      assert found == report(7, {:failed, :timeout})
    end
  end
end
