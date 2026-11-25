# A minimal host LiveView so the component's grab event actually runs (render_component/2 only
# renders, it doesn't process events). It forwards the {:manual_grab, …} the component sends to
# its parent on to the test pid, mirroring CinderWeb.ManualSearchHostLive for movies/TV.
defmodule CinderWeb.BookManualSearchHostLive do
  @moduledoc false
  use Phoenix.LiveView

  alias Cinder.Acquisition.EbookRelease
  alias Cinder.Books.BookTarget

  @results %{
    accepted: [
      {%EbookRelease{title: "Author - Title (EPUB)", download_url: "url-a", protocol: :torrent},
       %{format: :epub, formats: [:epub], language: nil, retail?: false, size: 2_000_000}}
    ],
    rejected: [],
    complete?: true
  }

  @impl true
  def mount(_params, %{"test_pid" => pid}, socket),
    do: {:ok, assign(socket, test_pid: pid, results: @results)}

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component
      module={CinderWeb.BookManualSearchComponent}
      id="ms"
      target={%BookTarget{id: 1, media_kind: :ebook, status: :monitored}}
      work={%{title: "Title", authors: ["Author"]}}
      results={@results}
    />
    """
  end

  @impl true
  def handle_info({:manual_grab, :book, _target, release}, socket) do
    send(socket.assigns.test_pid, {:grabbed, release})
    {:noreply, socket}
  end
end

defmodule CinderWeb.BookManualSearchComponentTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Cinder.Acquisition.{AudiobookRelease, BookScorer, EbookRelease}
  alias Cinder.Acquisition.IndexerSource.Report
  alias Cinder.Books.BookTarget
  alias CinderWeb.BookManualSearchComponent
  alias Phoenix.LiveView.Socket

  # A pre-seeded `results:` assign makes `update/2` skip the async indexer fetch, so the panel can
  # be rendered and asserted without a host LiveView or Mox — mirrors
  # `ManualSearchComponentTest.render_panel/1`.
  defp render_panel(results) do
    render_component(BookManualSearchComponent, %{
      id: "ms",
      target: %BookTarget{id: 1, media_kind: :ebook, status: :monitored},
      work: %{title: "Title", authors: ["Author"]},
      results: results
    })
  end

  defp release(title, attrs \\ %{}),
    do: EbookRelease.new(Map.merge(%{title: title, download_url: "u", protocol: :torrent}, attrs))

  defp evidence(attrs \\ %{}),
    do:
      Map.merge(
        %{format: :epub, formats: [:epub], language: nil, retail?: false, size: 2_000_000},
        attrs
      )

  defp render_audiobook_panel(results) do
    render_component(BookManualSearchComponent, %{
      id: "ms",
      target: %BookTarget{id: 1, media_kind: :audiobook, status: :monitored},
      work: %{title: "Title", authors: ["Author"]},
      results: results
    })
  end

  defp audiobook_evidence(attrs),
    do:
      Map.merge(
        %{
          format: :m4b,
          formats: [:m4b],
          language: nil,
          retail?: false,
          size: 629_145_600,
          narrator: nil
        },
        attrs
      )

  test "an accepted row shows format, language, retail and size with a Grab button" do
    html =
      render_panel(%{
        accepted: [
          {release("Author - Title (EPUB) [retail]"),
           evidence(%{format: :epub, language: "eng", retail?: true, size: 6_291_456})}
        ],
        rejected: [],
        complete?: true
      })

    assert html =~ "Author - Title (EPUB) [retail]"
    assert html =~ "EPUB"
    assert html =~ "eng"
    assert html =~ "retail"
    assert html =~ "6.0 MB"
    assert html =~ "Grab"
  end

  describe "an audiobook target" do
    test "an accepted row also shows the narrator credit" do
      html =
        render_audiobook_panel(%{
          accepted: [
            {AudiobookRelease.new(%{title: "Author - Title (M4B) [retail]", download_url: "u"}),
             audiobook_evidence(%{retail?: true, narrator: "Ray Porter"})}
          ],
          rejected: [],
          complete?: true
        })

      assert html =~ "M4B"
      assert html =~ "retail"
      assert html =~ "Narrated by Ray Porter"
      assert html =~ "600.0 MB"
      assert html =~ "Grab"
    end

    test "an unparsed narrator renders no narrator line at all, not a blank label" do
      html =
        render_audiobook_panel(%{
          accepted: [
            {AudiobookRelease.new(%{title: "Author - Title (M4B)", download_url: "u"}),
             audiobook_evidence(%{narrator: nil})}
          ],
          rejected: [],
          complete?: true
        })

      refute html =~ "Narrated by"
    end
  end

  test "an e-book row has no narrator line" do
    html =
      render_panel(%{
        accepted: [{release("Author - Title (EPUB)"), evidence()}],
        rejected: [],
        complete?: true
      })

    refute html =~ "Narrated by"
  end

  test "an untagged release renders as untagged, not blank" do
    html =
      render_panel(%{
        accepted: [{release("Author - Title (EPUB)"), evidence(%{language: nil})}],
        rejected: [],
        complete?: true
      })

    assert html =~ "untagged"
  end

  test "a rejected row shows its reason and no Grab button" do
    html =
      render_panel(%{
        accepted: [],
        rejected: [{release("Author - Title (PDF)"), :format_rejected}],
        complete?: true
      })

    assert html =~ "Author - Title (PDF)"
    assert html =~ "format not accepted"
    refute html =~ "Grab"
  end

  test "every BookScorer.reasons/0 atom renders real, non-atom-name copy" do
    by_reason =
      for reason <- BookScorer.reasons() do
        html = render_panel(%{accepted: [], rejected: [{release("R"), reason}], complete?: true})

        # Extract just the rejected-reason span's text, so groups of reasons can be compared for
        # distinctness below rather than asserting on the whole HTML blob.
        [_full, text] = Regex.run(~r/text-xs text-warning">([^<]*)</, html)
        text = String.trim(text)

        refute text == "", "#{inspect(reason)} rendered no copy"
        refute text == Atom.to_string(reason), "#{inspect(reason)} rendered its own atom name"
        {reason, text}
      end

    # Every reason renders copy distinct from every other reason's, with exactly one deliberate
    # exception: `:title_mismatch` and `:title_unfoldable` share "title doesn't match" because
    # both mean the release doesn't name this work (the B4c plan's rejection-copy table).
    by_reason
    |> Enum.group_by(fn {_reason, text} -> text end, fn {reason, _text} -> reason end)
    |> Enum.each(fn {_text, reasons} ->
      assert length(reasons) == 1 or Enum.sort(reasons) == [:title_mismatch, :title_unfoldable],
             "unexpected shared copy across #{inspect(reasons)}"
    end)
  end

  test "a reason outside BookScorer.reasons/0 renders the generic fallback, never its own name" do
    html =
      render_panel(%{
        accepted: [],
        rejected: [{release("R"), :some_future_reason_not_yet_wired}],
        complete?: true
      })

    refute html =~ "some_future_reason_not_yet_wired"
    assert html =~ "rejected"
  end

  test "complete?: false shows the incomplete-search banner even with accepted results" do
    html =
      render_panel(%{
        accepted: [{release("Author - Title (EPUB)"), evidence()}],
        rejected: [],
        complete?: false
      })

    assert html =~ "may be incomplete"
  end

  test "no results and a complete search says so plainly" do
    html = render_panel(%{accepted: [], rejected: [], complete?: true})

    assert html =~ "No releases found."
    refute html =~ "may be incomplete"
  end

  test "clicking Grab forwards {:manual_grab, :book, target, release} to the parent" do
    {:ok, lv, _html} =
      live_isolated(build_conn(), CinderWeb.BookManualSearchHostLive,
        session: %{"test_pid" => self()}
      )

    lv |> element("button[phx-value-index='0']", "Grab") |> render_click()

    assert_receive {:grabbed, %EbookRelease{download_url: "url-a"}}
  end

  test "a grab event through the real update/2 flow, with :results genuinely never assigned, is a no-op — not a crash" do
    # The bug this proves fixed: `handle_event("grab", …)` used to dereference
    # `socket.assigns.results.accepted` unconditionally, and `:results` was only ever assigned by
    # `handle_async` or a preseed — so a "grab" arriving while `state` was `:loading` or `:error`
    # raised `KeyError` and took the parent LiveView down with it.
    #
    # A hand-built socket that already carries `:results` (the first version of this test) never
    # exercised that: `handle_event/3` itself is byte-for-byte unchanged by the fix — only
    # `update/2` changed, and only `update/2` decides whether `:results` exists at all. So this
    # calls the real `update/2` (not a fabricated socket) to reach the genuinely-unset state, the
    # same way a first, disconnected render or a stalled connected one would in production: no
    # `transport_pid`, so `connected?/1` is false and `update/2` takes its "not yet connected"
    # branch, which — pre-fix — touched `:state` and never `:results` at all.
    assigns = %{
      id: "ms",
      target: %BookTarget{id: 1, media_kind: :ebook, status: :monitored},
      work: %{title: "Title", authors: ["Author"]}
    }

    socket = %Socket{assigns: %{__changed__: %{}}}

    assert {:ok, loading} = BookManualSearchComponent.update(assigns, socket)
    assert loading.assigns.state == :loading

    assert {:noreply, _socket} =
             BookManualSearchComponent.handle_event("grab", %{"index" => "0"}, loading)

    refute_received {:manual_grab, _mode, _target, _release}
  end

  test "a malformed grab index against a real :loaded socket is ignored, not a crash" do
    results = %{
      accepted: [{release("Author - Title (EPUB)"), evidence()}],
      rejected: [],
      complete?: true
    }

    assigns = %{
      id: "ms",
      target: %BookTarget{id: 1, media_kind: :ebook, status: :monitored},
      work: %{title: "Title", authors: ["Author"]},
      results: results
    }

    socket = %Socket{assigns: %{__changed__: %{}}}
    assert {:ok, loaded} = BookManualSearchComponent.update(assigns, socket)
    assert loaded.assigns.state == :loaded

    for params <- [%{"index" => "-1"}, %{"index" => "abc"}, %{"index" => "1.5"}, %{}] do
      assert match?(
               {:noreply, _socket},
               BookManualSearchComponent.handle_event("grab", params, loaded)
             ),
             "expected #{inspect(params)} to be a no-op"

      refute_received {:manual_grab, _mode, _target, _release}
    end
  end

  test ":loading renders a spinner, and :error renders its reason's text — not just :loaded" do
    loading_html =
      render_component(BookManualSearchComponent, %{
        id: "ms",
        target: %BookTarget{id: 1, media_kind: :ebook, status: :monitored},
        work: %{title: "Title", authors: ["Author"]},
        state: :loading
      })

    assert loading_html =~ "Searching releases"
    refute loading_html =~ "No releases found."

    error_html =
      render_component(BookManualSearchComponent, %{
        id: "ms",
        target: %BookTarget{id: 1, media_kind: :ebook, status: :monitored},
        work: %{title: "Title", authors: ["Author"]},
        state: :error,
        error: :no_indexers
      })

    assert texts(error_html, "#ms-error") == ["No indexer is enabled. Add one in Settings."]
    refute error_html =~ "No releases found."
  end

  test "handle_async transitions :loading to :loaded on success and :error on failure/exit" do
    socket = %Socket{assigns: %{__changed__: %{}, state: :loading, results: %{}}}
    result = %{accepted: [], rejected: [], complete?: true}

    assert {:noreply, ok_socket} =
             BookManualSearchComponent.handle_async(:search, {:ok, {:ok, result}}, socket)

    assert ok_socket.assigns.state == :loaded
    assert ok_socket.assigns.results == result

    assert {:noreply, error_socket} =
             BookManualSearchComponent.handle_async(:search, {:ok, {:error, :timeout}}, socket)

    assert error_socket.assigns.state == :error

    assert {:noreply, exit_socket} =
             BookManualSearchComponent.handle_async(:search, {:exit, :killed}, socket)

    assert exit_socket.assigns.state == :error
  end

  # #495: the accepted/rejected partition was scored against the OLD preferred_language and must
  # never survive a language change while the panel stays open — mirrors
  # ManualSearchComponentTest's own "a metadata refresh that moves the resolved audio target
  # restarts the search" unit test of `update/2` directly, no host LiveView needed.
  test "a target language change invalidates the loaded accepted/rejected partition" do
    target = fn language ->
      %BookTarget{id: 1, media_kind: :ebook, status: :monitored, preferred_language: language}
    end

    work = %{title: "Title", authors: ["Author"]}

    loaded = %Socket{
      assigns: %{
        __changed__: %{},
        id: "ms",
        target: target.("en"),
        work: work,
        state: :loaded,
        results: %{
          accepted: [{release("Old English Release"), evidence()}],
          rejected: [{release("Old Rejected"), :language_mismatch}],
          complete?: true
        }
      }
    }

    assert {:ok, updated} =
             BookManualSearchComponent.update(
               %{id: "ms", target: target.("fr"), work: work},
               loaded
             )

    assert updated.assigns.state == :loading
    assert updated.assigns.results == %{accepted: [], rejected: [], complete?: true}
  end

  test "an unrelated re-render (same language) keeps the loaded results as they are" do
    target = %BookTarget{id: 1, media_kind: :ebook, status: :monitored, preferred_language: "en"}
    work = %{title: "Title", authors: ["Author"]}
    results = %{accepted: [{release("Kept Release"), evidence()}], rejected: [], complete?: true}

    loaded = %Socket{
      assigns: %{
        __changed__: %{},
        id: "ms",
        target: target,
        work: work,
        state: :loaded,
        results: results
      }
    }

    assert {:ok, updated} =
             BookManualSearchComponent.update(%{id: "ms", target: target, work: work}, loaded)

    assert updated.assigns.state == :loaded
    assert updated.assigns.results == results
  end

  # A delayed pre-change search task completing AFTER a language change must not land: covered at
  # the Phoenix.LiveView.Async level (its own ref-tracking drops a result whose ref no longer
  # matches the socket's current one for a key — see `Phoenix.LiveView.Async.prune_current_async/3`
  # and the comment on `context_changed?` in the component itself), so `handle_async/3` firing with
  # the component's OWN stale-context assigns still in place (as it would if delivered) must not
  # be reachable in practice; this test instead pins the precondition that makes the drop happen:
  # a language change always assigns a fresh `:search_context`, which is exactly what changes the
  # tracked async ref on the next `start_search/1` call.
  test "a language change always assigns a fresh search_context, invalidating the async ref lookup" do
    target = fn language ->
      %BookTarget{id: 1, media_kind: :ebook, status: :monitored, preferred_language: language}
    end

    work = %{title: "Title", authors: ["Author"]}

    loaded = %Socket{
      assigns: %{
        __changed__: %{},
        id: "ms",
        target: target.("en"),
        work: work,
        state: :loaded,
        results: %{accepted: [], rejected: [], complete?: true},
        search_context: {1, "en"}
      }
    }

    assert {:ok, updated} =
             BookManualSearchComponent.update(
               %{id: "ms", target: target.("fr"), work: work},
               loaded
             )

    assert updated.assigns.search_context == {1, "fr"}
  end

  # The text of every element `selector` matches in `html`, whitespace collapsed.
  defp texts(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))
  end

  defp report(entries, failed_calls \\ 0) do
    report =
      Enum.reduce(entries, Report.new(), fn {id, name, outcome}, acc ->
        Report.put(acc, {"native", id}, name, outcome)
      end)

    %{report | failed_calls: failed_calls}
  end

  describe "what the search's report and error say (#1648)" do
    setup do
      # Asia/Tokyo is UTC+9 all year, so a household time differs from UTC's by a fixed amount.
      Cinder.ConfigCase.put_env(:household_timezone, "Asia/Tokyo")
      :ok
    end

    test "accepted and rejected rows show their release's indexer name; a row with none shows nothing" do
      html =
        render_panel(%{
          accepted: [
            {release("Author - Title (EPUB)", %{indexer_name: "NZBgeek"}), evidence()},
            {release("Author - Title (AZW3)"), evidence()}
          ],
          rejected: [
            {release("Author - Title (PDF)", %{indexer_name: "NZBgeek"}), :format_rejected},
            {release("Author - Title (MOBI)"), :format_rejected}
          ],
          complete?: true
        })

      assert texts(html, "#ms li [data-indexer]") == ["NZBgeek", "NZBgeek"]
      assert [accepted, accepted_unnamed, rejected, rejected_unnamed] = texts(html, "#ms li")
      assert accepted =~ "Author - Title (EPUB) NZBgeek"
      assert rejected =~ "Author - Title (PDF) NZBgeek"
      refute accepted_unnamed =~ "NZBgeek"
      refute rejected_unnamed =~ "NZBgeek"
    end

    test "an audiobook row shows its release's indexer name" do
      html =
        render_audiobook_panel(%{
          accepted: [
            {AudiobookRelease.new(%{
               title: "Author - Title (M4B)",
               download_url: "u",
               indexer_name: "MyAnonamouse"
             }), audiobook_evidence(%{})}
          ],
          rejected: [],
          complete?: true
        })

      assert texts(html, "#ms li [data-indexer]") == ["MyAnonamouse"]
    end

    test "a loaded panel names each failed or skipped indexer from the results' report" do
      today =
        Cinder.Settings.household_date() |> DateTime.new!(~T[14:35:00], "Asia/Tokyo")

      html =
        render_panel(%{
          accepted: [{release("Author - Title (EPUB)"), evidence()}],
          rejected: [],
          complete?: false,
          report:
            report([
              {1, "One", {:failed, :timeout}},
              {2, "Two", {:skipped, {:backoff, today}}},
              {3, "Answered", :asked}
            ])
        })

      assert texts(html, "#ms-unanswered") == [
               "Not every indexer answered: One (timed out), Two (waiting until 14:35)."
             ]

      # complete?: false still shows the incomplete line, beside the named failures.
      assert texts(html, "#ms-incomplete") == [
               "Some indexers could not be reached; results may be incomplete."
             ]
    end

    test "a report that counts a failed seam call shows the incomplete line" do
      # `complete?: true` here, so the report's count alone is what shows the line.
      html =
        render_panel(%{
          accepted: [],
          rejected: [],
          complete?: true,
          report: report([], 1)
        })

      assert texts(html, "#ms-incomplete") == [
               "Some indexers could not be reached; results may be incomplete."
             ]

      assert texts(html, "#ms-unanswered") == []
    end

    test "each search error renders its own text, and a no-answer error its report's line" do
      no_answer = report([{1, "One", {:failed, :rejected_credentials}}])

      table = [
        {{:no_indexer_answered, no_answer}, "No indexer answered. Try again."},
        {:no_indexers, "No indexer is enabled. Add one in Settings."},
        {{:indexers_backing_off,
          DateTime.new!(Cinder.Settings.household_date(), ~T[14:35:00], "Asia/Tokyo")},
         "Every indexer is waiting until 14:35."},
        {{:prowlarr_status, 500}, "Couldn't reach Prowlarr. Try again."},
        {{:exit, :killed}, "The search failed. Try again."}
      ]

      for {reason, text} <- table do
        html =
          render_component(BookManualSearchComponent, %{
            id: "ms",
            target: %BookTarget{id: 1, media_kind: :ebook, status: :monitored},
            work: %{title: "Title", authors: ["Author"]},
            state: :error,
            error: reason
          })

        assert texts(html, "#ms-error") == [text], "reason #{inspect(reason)}"

        expected_line =
          if match?({:no_indexer_answered, _}, reason),
            do: ["Not every indexer answered: One (credentials rejected)."],
            else: []

        assert texts(html, "#ms-unanswered") == expected_line, "reason #{inspect(reason)}"
      end
    end

    test "handle_async keeps the error reason, a task exit included" do
      socket = %Socket{assigns: %{__changed__: %{}, state: :loading, results: %{}}}

      assert {:noreply, failed} =
               BookManualSearchComponent.handle_async(
                 :search,
                 {:ok, {:error, {:prowlarr_status, 502}}},
                 socket
               )

      assert %{state: :error, error: {:prowlarr_status, 502}} = failed.assigns

      assert {:noreply, exited} =
               BookManualSearchComponent.handle_async(:search, {:exit, :killed}, socket)

      assert %{state: :error, error: {:exit, :killed}} = exited.assigns

      result = %{accepted: [], rejected: [], complete?: true, report: Report.new()}

      assert {:noreply, loaded} =
               BookManualSearchComponent.handle_async(:search, {:ok, {:ok, result}}, failed)

      assert %{state: :loaded, results: ^result, error: nil} = loaded.assigns
    end

    test "a language change drops the old error" do
      target = fn language ->
        %BookTarget{id: 1, media_kind: :ebook, status: :monitored, preferred_language: language}
      end

      work = %{title: "Title", authors: ["Author"]}

      failed = %Socket{
        assigns: %{
          __changed__: %{},
          id: "ms",
          target: target.("en"),
          work: work,
          state: :error,
          error: :no_indexers,
          results: %{accepted: [], rejected: [], complete?: true},
          search_context: {1, "en"}
        }
      }

      assert {:ok, updated} =
               BookManualSearchComponent.update(
                 %{id: "ms", target: target.("fr"), work: work},
                 failed
               )

      assert updated.assigns.state == :loading
      assert updated.assigns.error == nil
    end
  end
end
