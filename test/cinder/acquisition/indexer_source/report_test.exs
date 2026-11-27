defmodule Cinder.Acquisition.IndexerSource.ReportTest do
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.IndexerSource.Report

  @until ~U[2030-01-01 00:00:00Z]
  @later ~U[2030-01-02 00:00:00Z]

  defp one(outcome, key \\ {"native", 1}, name \\ "Indexer One"),
    do: Report.put(Report.new(), key, name, outcome)

  defp outcome(report, key \\ {"native", 1}), do: report.indexers[key].outcome

  # `value`, typed as any term, so the compiler's type check lets a test pass a value the spec
  # refuses: `:erlang.binary_to_term/1` returns `term()`.
  defp untyped(value), do: value |> :erlang.term_to_binary() |> :erlang.binary_to_term()

  describe "merge/2" do
    # Each pair is {winner, loser} under failed over skipped over asked over not asked.
    @ranked [
      {{:failed, :timeout}, {:skipped, :deadline}},
      {{:failed, :timeout}, :asked},
      {{:failed, :timeout}, {:not_asked, :caps}},
      {{:skipped, :deadline}, :asked},
      {{:skipped, :deadline}, {:not_asked, :caps}},
      {:asked, {:not_asked, :caps}}
    ]

    test "keeps failed over skipped over asked over not asked, in both argument orders" do
      wrong =
        for {winner, loser} <- @ranked,
            {a, b} <- [{winner, loser}, {loser, winner}],
            cell = {a, b, outcome(Report.merge(one(a), one(b)))},
            cell != {a, b, winner},
            do: cell

      assert wrong == []
    end

    test "on a tie keeps the earlier seam call's reason and name" do
      first = one({:failed, :timeout}, {"native", 1}, "First name")
      second = one({:failed, :dns}, {"native", 1}, "Second name")

      assert %{name: "First name", outcome: {:failed, :timeout}} =
               Report.merge(first, second).indexers[{"native", 1}]

      assert %{name: "Second name", outcome: {:failed, :dns}} =
               Report.merge(second, first).indexers[{"native", 1}]

      skipped = Report.merge(one({:skipped, {:backoff, @until}}), one({:skipped, :deadline}))
      assert outcome(skipped) == {:skipped, {:backoff, @until}}

      not_asked = Report.merge(one({:not_asked, :caps}), one({:not_asked, {:not_supported, :x}}))
      assert outcome(not_asked) == {:not_asked, :caps}
    end

    test "keeps every indexer of either side and adds the failed-call counts" do
      a = %{one(:asked, {"native", 1}) | failed_calls: 2}
      b = %{one({:skipped, :deadline}, {"prowlarr", 1}) | failed_calls: 3}

      merged = Report.merge(a, b)

      assert merged.failed_calls == 5
      assert outcome(merged, {"native", 1}) == :asked
      assert outcome(merged, {"prowlarr", 1}) == {:skipped, :deadline}
    end
  end

  describe "incomplete?/1" do
    test "is true for a failed seam call alone and for a failed indexer alone" do
      assert Report.incomplete?(%{Report.new() | failed_calls: 1})
      assert Report.incomplete?(one({:failed, :timeout}))
    end

    test "is false for an empty report and for skipped, not-asked and asked indexers" do
      refute Report.incomplete?(Report.new())

      report =
        Report.new()
        |> Report.put({"native", 1}, "A", :asked)
        |> Report.put({"native", 2}, "B", {:skipped, {:backoff, @until}})
        |> Report.put({"native", 3}, "C", {:skipped, :deadline})
        |> Report.put({"native", 4}, "D", {:not_asked, :caps})
        |> Report.put({"native", 5}, "E", {:not_asked, {:not_supported, {:login, :form}}})

      refute Report.incomplete?(report)
    end
  end

  describe "the closed set of outcomes" do
    @valid [
      :asked,
      {:not_asked, :caps},
      {:not_asked, {:not_supported, :html_search}},
      {:not_asked, {:not_supported, {:login, :form}}},
      {:skipped, {:backoff, @until}},
      {:skipped, :deadline},
      {:failed, :timeout},
      {:failed, :dns},
      {:failed, :connection_refused},
      {:failed, :connection_failed},
      {:failed, {:http_status, 503}},
      {:failed, :bad_response},
      {:failed, :too_large},
      {:failed, {:indexer_error, 900}},
      {:failed, {:limit, @later}},
      {:failed, {:limit, nil}},
      {:failed, :rejected_credentials},
      {:failed, :challenge},
      {:failed, :crashed},
      # #1682's FlareSolverr step.
      {:failed, :cloudflare_challenge},
      {:failed, :flaresolverr_url_not_set},
      {:failed, :flaresolverr_failed},
      {:failed, :flaresolverr_off_host}
    ]

    @invalid [
      :failed,
      {:asked, :timeout},
      {:not_asked, :deadline},
      {:not_asked, {:not_supported, "html_search"}},
      {:not_asked, {:not_supported, {:login, "form"}}},
      {:not_asked, {:not_supported, {}}},
      {:skipped, :timeout},
      {:skipped, {:backoff, "2030-01-01"}},
      {:skipped, {:limit, @until}},
      {:failed, :caps},
      {:failed, :deadline},
      {:failed, {:http_status, "503"}},
      {:failed, {:http_status, 99}},
      {:failed, {:http_status, 600}},
      {:failed, {:indexer_error, "900"}},
      {:failed, {:limit, 1_900_000_000}},
      {:failed, {:limit, "2030-01-01"}},
      {:skipped, {:limit, nil}},
      {:failed, {:backoff, @until}},
      {:failed, "https://indexer.example/api?apikey=secret"},
      {:failed, {:bad_response, "<html>body</html>"}}
    ]

    test "outcome?/1 accepts each outcome of the closed set and refuses each listed other term" do
      assert Enum.reject(@valid, &Report.outcome?/1) == []
      assert Enum.filter(@invalid, &Report.outcome?/1) == []
    end

    test "put/4 records an outcome of the set and raises on any other" do
      for outcome <- @valid, do: assert(outcome(one(outcome)) == outcome)

      for outcome <- @invalid do
        assert_raise ArgumentError, fn -> one(outcome) end
      end
    end

    test "put/4 refuses a key other than a source string and an integer id" do
      assert_raise FunctionClauseError, fn -> one(:asked, untyped({:native, 1})) end
      assert_raise FunctionClauseError, fn -> one(:asked, untyped({"native", "1"})) end
    end

    test "put/4 merges a second outcome for the same indexer by the merge rule" do
      report =
        Report.new()
        |> Report.put({"native", 1}, "A", :asked)
        |> Report.put({"native", 1}, "A", {:failed, :timeout})
        |> Report.put({"native", 1}, "A", {:skipped, :deadline})

      assert outcome(report) == {:failed, :timeout}
    end
  end

  describe "from_result/1" do
    test "gives a 2-tuple answer an empty report and passes a 3-tuple and an error through" do
      report = one({:failed, :timeout})

      assert Report.from_result({:ok, [:row]}) == {:ok, [:row], Report.new()}
      assert Report.from_result({:ok, [:row], report}) == {:ok, [:row], report}
      assert Report.from_result({:error, :timeout}) == {:error, :timeout}
    end

    test "raises on an answer of any other shape" do
      assert_raise FunctionClauseError, fn -> Report.from_result(untyped({:ok, [], %{}})) end
      assert_raise FunctionClauseError, fn -> Report.from_result(untyped({:ok, :not_a_list})) end
      assert_raise FunctionClauseError, fn -> Report.from_result(untyped(:ok)) end
    end
  end

  describe "combine/1" do
    defp backing_off(at), do: {:error, {:indexers_backing_off, at}}
    defp unanswered(report), do: {:error, {:no_indexer_answered, report}}

    test "gives no calls an empty answer with an empty report" do
      assert Report.combine([]) == {:ok, [], Report.new()}
    end

    test "with some call answering, keeps each answer's rows in call order and merges reports" do
      first = one({:failed, :timeout}, {"native", 1}, "First")
      second = one({:failed, :dns}, {"native", 1}, "Second")

      assert {:ok, [[:a], [:b]], report} =
               Report.combine([{:ok, [:a], first}, {:ok, [:b], second}])

      assert report.indexers[{"native", 1}] == %{name: "First", outcome: {:failed, :timeout}}
      assert report.failed_calls == 0
    end

    test "with some call answering, a backoff or :no_indexers adds nothing" do
      assert {:ok, [[:a]], report} =
               Report.combine([
                 {:ok, [:a], Report.new()},
                 backing_off(@until),
                 {:error, :no_indexers}
               ])

      assert report == Report.new()
      refute Report.incomplete?(report)
    end

    test "with some call answering, an unanswered call adds its indexers and one failed call" do
      failed = one({:failed, :timeout}, {"native", 2}, "Two")

      assert {:ok, [[:a]], report} =
               Report.combine([{:ok, [:a], Report.new()}, unanswered(failed)])

      assert report.indexers == failed.indexers
      assert report.failed_calls == 1
    end

    test "with some call answering, any other error adds one failed call" do
      assert {:ok, [[:a]], report} =
               Report.combine([{:error, :timeout}, {:ok, [:a], Report.new()}, {:error, :x}])

      assert report.failed_calls == 2
      assert report.indexers == %{}
    end

    test "with no call answering, the first error that is neither a backoff nor :no_indexers wins" do
      assert Report.combine([backing_off(@until), {:error, :timeout}, {:error, :dns}]) ==
               {:error, :timeout}

      assert Report.combine([{:error, :no_indexers}, {:error, {:prowlarr_status, 500}}]) ==
               {:error, {:prowlarr_status, 500}}
    end

    test "with no call answering, every unanswered call's report merges into a winning one" do
      first = one({:failed, :timeout}, {"native", 1}, "One")
      second = one({:failed, :dns}, {"native", 2}, "Two")
      tie = one({:failed, :dns}, {"native", 1}, "One again")

      assert {:error, {:no_indexer_answered, report}} =
               Report.combine([
                 backing_off(@until),
                 unanswered(first),
                 {:error, :timeout},
                 unanswered(second),
                 unanswered(tie)
               ])

      assert report.indexers == %{
               {"native", 1} => %{name: "One", outcome: {:failed, :timeout}},
               {"native", 2} => %{name: "Two", outcome: {:failed, :dns}}
             }

      assert report.failed_calls == 0
    end

    test "with no call answering, a winning other error stays as it is beside unanswered calls" do
      assert Report.combine([{:error, :timeout}, unanswered(one({:failed, :dns}))]) ==
               {:error, :timeout}
    end

    test "with no call answering and only backoffs, the backoff with the earliest retry_at wins" do
      assert Report.combine([backing_off(@later), backing_off(@until), backing_off(@later)]) ==
               backing_off(@until)

      assert Report.combine([backing_off(@until), backing_off(@later)]) == backing_off(@until)
    end

    test "with no call answering, a backoff wins over :no_indexers, which comes last" do
      assert Report.combine([{:error, :no_indexers}, backing_off(@later)]) == backing_off(@later)
      assert Report.combine([{:error, :no_indexers}]) == {:error, :no_indexers}
    end

    test "a one-call search's error comes back unchanged" do
      report = one({:failed, :timeout})
      assert Report.combine([unanswered(report)]) == unanswered(report)
    end
  end
end
