# The household zone is a process-global `:cinder` env key (`Cinder.ConfigCase.put_env/2`), so
# this module is not async.
defmodule CinderWeb.SearchReportComponentsTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias Cinder.Acquisition.IndexerSource.Report
  alias Cinder.ConfigCase
  alias CinderWeb.SearchReportComponents

  # 10:00 on Jun 3 in Tokyo (UTC+9 all year), the household's "now" for every time below.
  @now ~U[2026-06-03 01:00:00Z]
  # 14:35 on Jun 3 in Tokyo: the household's today.
  @today_1435 ~U[2026-06-03 05:35:00Z]
  # 14:35 on Jun 5 in Tokyo.
  @later_1435 ~U[2026-06-05 05:35:00Z]

  setup do
    ConfigCase.put_env(:household_timezone, "Asia/Tokyo")
    Gettext.put_locale(CinderWeb.Gettext, "en")
    :ok
  end

  defp report(entries) do
    Enum.reduce(entries, Report.new(), fn {id, name, outcome}, acc ->
      Report.put(acc, {"native", id}, name, outcome)
    end)
  end

  defp render_line(report) do
    render_component(&SearchReportComponents.unanswered_indexers/1, %{
      id: "line",
      report: report,
      now: @now
    })
  end

  # The text of every element `selector` matches in `html`, whitespace collapsed.
  defp texts(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))
  end

  describe "unanswered_indexers/1" do
    test "each reason tag of the report renders its own text" do
      table = [
        {{:failed, :timeout}, "timed out"},
        {{:failed, :dns}, "couldn't connect"},
        {{:failed, :connection_refused}, "couldn't connect"},
        {{:failed, :connection_failed}, "couldn't connect"},
        {{:failed, {:http_status, 503}}, "HTTP 503"},
        {{:failed, :bad_response}, "unreadable answer"},
        {{:failed, :too_large}, "answer too large"},
        {{:failed, {:indexer_error, 900}}, "error code 900"},
        {{:failed, {:limit, @today_1435}}, "limit reached, searching again at 14:35"},
        {{:failed, :rejected_credentials}, "credentials rejected"},
        {{:failed, :challenge}, "blocked by a challenge page"},
        {{:failed, :crashed}, "search crashed"},
        {{:skipped, {:backoff, @today_1435}}, "waiting until 14:35"},
        {{:skipped, :deadline}, "cut off by the search deadline"}
      ]

      for {outcome, reason} <- table do
        html = render_line(report([{1, "One", outcome}]))

        assert texts(html, "#line") == ["Not every indexer answered: One (#{reason})."],
               "outcome #{inspect(outcome)}"
      end
    end

    test "a limit or a backoff that ends on another household day shows its date" do
      html =
        render_line(
          report([
            {1, "One", {:failed, {:limit, @later_1435}}},
            {2, "Two", {:skipped, {:backoff, @later_1435}}}
          ])
        )

      assert texts(html, "#line") == [
               "Not every indexer answered: One (limit reached, searching again on Jun 5 at 14:35), " <>
                 "Two (waiting until Jun 5, 14:35)."
             ]
    end

    test "the French catalog words each time sentence for today and for another day" do
      Gettext.put_locale(CinderWeb.Gettext, "fr")

      today =
        render_line(
          report([
            {1, "One", {:failed, {:limit, @today_1435}}},
            {2, "Two", {:skipped, {:backoff, @today_1435}}}
          ])
        )

      later =
        render_line(
          report([
            {1, "One", {:failed, {:limit, @later_1435}}},
            {2, "Two", {:skipped, {:backoff, @later_1435}}}
          ])
        )

      assert texts(today, "#line") == [
               "Certains indexeurs n'ont pas répondu : One (limite atteinte, nouvelle recherche " <>
                 "à 14:35), Two (en attente jusqu'à 14:35)."
             ]

      assert texts(later, "#line") == [
               "Certains indexeurs n'ont pas répondu : One (limite atteinte, nouvelle recherche " <>
                 "le 5 juin à 14:35), Two (en attente jusqu'au 5 juin à 14:35)."
             ]

      assert SearchReportComponents.search_error_text({:indexers_backing_off, @today_1435}, @now) ==
               "Tous les indexeurs sont en attente jusqu'à 14:35."

      assert SearchReportComponents.search_error_text({:indexers_backing_off, @later_1435}, @now) ==
               "Tous les indexeurs sont en attente jusqu'au 5 juin à 14:35."
    after
      Gettext.put_locale(CinderWeb.Gettext, "en")
    end

    test "lists the failed and skipped indexers by name, whatever their keys' order" do
      # Keys run Zulu, Mike, Alpha; the line runs by name.
      html =
        render_line(
          report([
            {1, "Zulu", {:failed, :timeout}},
            {2, "Mike", {:skipped, :deadline}},
            {3, "Alpha", {:failed, :too_large}}
          ])
        )

      assert texts(html, "#line") == [
               "Not every indexer answered: Alpha (answer too large), " <>
                 "Mike (cut off by the search deadline), Zulu (timed out)."
             ]
    end

    test "an indexer that answered or was not asked is not listed" do
      html =
        render_line(
          report([
            {1, "Asked", :asked},
            {2, "Caps", {:not_asked, :caps}},
            {3, "Unsupported", {:not_asked, {:not_supported, :login}}},
            {4, "Failed", {:failed, :timeout}}
          ])
        )

      assert texts(html, "#line") == ["Not every indexer answered: Failed (timed out)."]
    end

    test "no line when no indexer failed or was skipped" do
      only_answered = report([{1, "Asked", :asked}, {2, "Caps", {:not_asked, :caps}}])

      # A Prowlarr search's report names no indexer, even with a failed seam call counted.
      prowlarr = %{Report.new() | failed_calls: 2}

      for report <- [only_answered, prowlarr, Report.new(), nil] do
        assert texts(render_line(report), "#line") == [], "report #{inspect(report)}"
      end
    end

    test "a reason outside the known tags shows the name alone, never the term" do
      odd = %Report{
        indexers: %{
          {"native", 1} => %{name: "Odd", outcome: {:failed, :some_new_reason}},
          {"native", 2} => %{name: "Odder", outcome: {:skipped, {:backoff, :not_a_datetime}}}
        }
      }

      html = render_line(odd)

      assert texts(html, "#line") == ["Not every indexer answered: Odd, Odder."]
      refute html =~ "some_new_reason"
      refute html =~ "not_a_datetime"
    end
  end

  describe "search_error_text/2" do
    test "one text per error reason" do
      table = [
        {{:no_indexer_answered, report([{1, "One", {:failed, :timeout}}])},
         "No indexer answered. Try again."},
        {:no_indexers, "No indexer is enabled. Add one in Settings."},
        {{:indexers_backing_off, @today_1435}, "Every indexer is waiting until 14:35."},
        {{:indexers_backing_off, @later_1435}, "Every indexer is waiting until Jun 5, 14:35."},
        {{:anime_policy, :original_language_required}, "The search failed. Try again."},
        {{:anime_policy, :subtitle_language_required}, "The search failed. Try again."},
        {{:exit, :killed}, "The search failed. Try again."},
        {nil, "The search failed. Try again."},
        {{:prowlarr_status, 500}, "Couldn't reach Prowlarr. Try again."},
        {:unexpected_response, "Couldn't reach Prowlarr. Try again."},
        {%Req.TransportError{reason: :econnrefused}, "Couldn't reach Prowlarr. Try again."},
        {:request_timeout, "Couldn't reach Prowlarr. Try again."},
        # A malformed typed reason falls to the catch-all instead of crashing the render.
        {{:indexers_backing_off, :not_a_datetime}, "Couldn't reach Prowlarr. Try again."},
        {{:no_indexer_answered, :not_a_report}, "Couldn't reach Prowlarr. Try again."}
      ]

      for {reason, text} <- table do
        assert SearchReportComponents.search_error_text(reason, @now) == text,
               "reason #{inspect(reason)}"
      end
    end

    test "error_report/1 gives the report only a no-answer error carries" do
      carried = report([{1, "One", {:failed, :timeout}}])

      assert SearchReportComponents.error_report({:no_indexer_answered, carried}) == carried
      assert SearchReportComponents.error_report({:no_indexer_answered, :not_a_report}) == nil
      assert SearchReportComponents.error_report(:no_indexers) == nil
      assert SearchReportComponents.error_report({:exit, :killed}) == nil
    end
  end

  describe "show_incomplete_line?/2" do
    test "a counted failed seam call shows the incomplete line, whatever complete? says" do
      assert SearchReportComponents.show_incomplete_line?(%{Report.new() | failed_calls: 1}, true)
      refute SearchReportComponents.show_incomplete_line?(Report.new(), true)
    end

    test "a named failure shows it only through complete?: false" do
      named = report([{1, "One", {:failed, :timeout}}])

      assert SearchReportComponents.show_incomplete_line?(named, false)
      refute SearchReportComponents.show_incomplete_line?(named, true)
    end

    test "with no report, complete?: false shows the incomplete line as before" do
      assert SearchReportComponents.show_incomplete_line?(nil, false)
      refute SearchReportComponents.show_incomplete_line?(nil, true)
    end
  end
end
