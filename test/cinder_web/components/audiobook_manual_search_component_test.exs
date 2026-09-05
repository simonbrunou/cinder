# A minimal host LiveView so the component's grab event actually runs (render_component/2 only
# renders, it doesn't process events). It forwards the {:manual_grab, …} the component sends to
# its parent on to the test pid, mirroring CinderWeb.BookManualSearchHostLive for e-books.
defmodule CinderWeb.AudiobookManualSearchHostLive do
  @moduledoc false
  use Phoenix.LiveView

  alias Cinder.Acquisition.AudiobookRelease
  alias Cinder.Books.BookTarget

  @results %{
    accepted: [
      {%AudiobookRelease{
         title: "Author - Title (M4B)",
         download_url: "url-a",
         protocol: :torrent
       },
       %{
         format: :m4b,
         formats: [:m4b],
         language: nil,
         retail?: false,
         size: 40_000_000,
         narrator: nil
       }}
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
      module={CinderWeb.AudiobookManualSearchComponent}
      id="ms"
      target={%BookTarget{id: 1, media_kind: :audiobook, status: :monitored}}
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

defmodule CinderWeb.AudiobookManualSearchComponentTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Cinder.Acquisition.{AudiobookRelease, AudiobookScorer}
  alias Cinder.Books.BookTarget
  alias CinderWeb.AudiobookManualSearchComponent
  alias Phoenix.LiveView.Socket

  # A pre-seeded `results:` assign makes `update/2` skip the async indexer fetch, so the panel can
  # be rendered and asserted without a host LiveView or Mox — mirrors
  # `BookManualSearchComponentTest.render_panel/1`.
  defp render_panel(results) do
    render_component(AudiobookManualSearchComponent, %{
      id: "ms",
      target: %BookTarget{id: 1, media_kind: :audiobook, status: :monitored},
      work: %{title: "Title", authors: ["Author"]},
      results: results
    })
  end

  defp release(title, attrs \\ %{}),
    do:
      AudiobookRelease.new(
        Map.merge(%{title: title, download_url: "u", protocol: :torrent}, attrs)
      )

  defp evidence(attrs \\ %{}),
    do:
      Map.merge(
        %{
          format: :m4b,
          formats: [:m4b],
          language: nil,
          retail?: false,
          size: 40_000_000,
          narrator: nil
        },
        attrs
      )

  test "an accepted row shows format, language, retail, narrator and size with a Grab button" do
    html =
      render_panel(%{
        accepted: [
          {release("Author - Title (M4B) [retail]"),
           evidence(%{
             format: :m4b,
             language: "eng",
             retail?: true,
             size: 629_145_600,
             narrator: "Ray Porter"
           })}
        ],
        rejected: [],
        complete?: true
      })

    assert html =~ "Author - Title (M4B) [retail]"
    assert html =~ "M4B"
    assert html =~ "eng"
    assert html =~ "retail"
    assert html =~ "Narrated by Ray Porter"
    assert html =~ "600.0 MB"
    assert html =~ "Grab"
  end

  test "an unparsed narrator renders no narrator line at all, not a blank label" do
    html =
      render_panel(%{
        accepted: [{release("Author - Title (M4B)"), evidence(%{narrator: nil})}],
        rejected: [],
        complete?: true
      })

    refute html =~ "Narrated by"
  end

  test "an untagged release renders as untagged, not blank" do
    html =
      render_panel(%{
        accepted: [{release("Author - Title (M4B)"), evidence(%{language: nil})}],
        rejected: [],
        complete?: true
      })

    assert html =~ "untagged"
  end

  test "a rejected row shows its reason and no Grab button" do
    html =
      render_panel(%{
        accepted: [],
        rejected: [{release("Author - Title (EPUB)"), :format_rejected}],
        complete?: true
      })

    assert html =~ "Author - Title (EPUB)"
    assert html =~ "format not accepted"
    refute html =~ "Grab"
  end

  test "every AudiobookScorer.reasons/0 atom renders real, non-atom-name copy" do
    by_reason =
      for reason <- AudiobookScorer.reasons() do
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
    # exception: `:title_mismatch` and `:title_unfoldable` share "title doesn't match" — mirrors
    # `BookManualSearchComponentTest`'s identical exception for the identical shared reason.
    by_reason
    |> Enum.group_by(fn {_reason, text} -> text end, fn {reason, _text} -> reason end)
    |> Enum.each(fn {_text, reasons} ->
      assert length(reasons) == 1 or Enum.sort(reasons) == [:title_mismatch, :title_unfoldable],
             "unexpected shared copy across #{inspect(reasons)}"
    end)
  end

  test "a reason outside AudiobookScorer.reasons/0 renders the generic fallback, never its own name" do
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
        accepted: [{release("Author - Title (M4B)"), evidence()}],
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
      live_isolated(build_conn(), CinderWeb.AudiobookManualSearchHostLive,
        session: %{"test_pid" => self()}
      )

    lv |> element("button[phx-value-index='0']", "Grab") |> render_click()

    assert_receive {:grabbed, %AudiobookRelease{download_url: "url-a"}}
  end

  test "a grab event through the real update/2 flow, with :results genuinely never assigned, is a no-op — not a crash" do
    # The exact e-book-side fix `BookManualSearchComponentTest` defends, mirrored here: `update/2`
    # decides whether `:results` exists at all, and a first/disconnected render must never let
    # `handle_event("grab", …)` dereference an unset `:results`.
    assigns = %{
      id: "ms",
      target: %BookTarget{id: 1, media_kind: :audiobook, status: :monitored},
      work: %{title: "Title", authors: ["Author"]}
    }

    socket = %Socket{assigns: %{__changed__: %{}}}

    assert {:ok, loading} = AudiobookManualSearchComponent.update(assigns, socket)
    assert loading.assigns.state == :loading

    assert {:noreply, _socket} =
             AudiobookManualSearchComponent.handle_event("grab", %{"index" => "0"}, loading)

    refute_received {:manual_grab, _mode, _target, _release}
  end

  test "a malformed grab index against a real :loaded socket is ignored, not a crash" do
    results = %{
      accepted: [{release("Author - Title (M4B)"), evidence()}],
      rejected: [],
      complete?: true
    }

    assigns = %{
      id: "ms",
      target: %BookTarget{id: 1, media_kind: :audiobook, status: :monitored},
      work: %{title: "Title", authors: ["Author"]},
      results: results
    }

    socket = %Socket{assigns: %{__changed__: %{}}}
    assert {:ok, loaded} = AudiobookManualSearchComponent.update(assigns, socket)
    assert loaded.assigns.state == :loaded

    for params <- [%{"index" => "-1"}, %{"index" => "abc"}, %{"index" => "1.5"}, %{}] do
      assert {:noreply, _socket} =
               AudiobookManualSearchComponent.handle_event("grab", params, loaded),
             "expected #{inspect(params)} to be a no-op"

      refute_received {:manual_grab, _mode, _target, _release}
    end
  end

  test ":loading renders a spinner, and :error renders the retry copy — not just :loaded" do
    loading_html =
      render_component(AudiobookManualSearchComponent, %{
        id: "ms",
        target: %BookTarget{id: 1, media_kind: :audiobook, status: :monitored},
        work: %{title: "Title", authors: ["Author"]},
        state: :loading
      })

    assert loading_html =~ "Searching releases"
    refute loading_html =~ "No releases found."

    error_html =
      render_component(AudiobookManualSearchComponent, %{
        id: "ms",
        target: %BookTarget{id: 1, media_kind: :audiobook, status: :monitored},
        work: %{title: "Title", authors: ["Author"]},
        state: :error
      })

    assert error_html =~ "reach the indexer"
  end

  test "handle_async transitions :loading to :loaded on success and :error on failure/exit" do
    socket = %Socket{assigns: %{__changed__: %{}, state: :loading, results: %{}}}
    result = %{accepted: [], rejected: [], complete?: true}

    assert {:noreply, ok_socket} =
             AudiobookManualSearchComponent.handle_async(:search, {:ok, {:ok, result}}, socket)

    assert ok_socket.assigns.state == :loaded
    assert ok_socket.assigns.results == result

    assert {:noreply, error_socket} =
             AudiobookManualSearchComponent.handle_async(
               :search,
               {:ok, {:error, :timeout}},
               socket
             )

    assert error_socket.assigns.state == :error

    assert {:noreply, exit_socket} =
             AudiobookManualSearchComponent.handle_async(:search, {:exit, :killed}, socket)

    assert exit_socket.assigns.state == :error
  end

  # #495: mirrors BookManualSearchComponentTest's own coverage — this module is that component's
  # verbatim-copied sibling (see the moduledoc), so the same context-invalidation bug and fix
  # apply here identically.
  test "a target language change invalidates the loaded accepted/rejected partition" do
    target = fn language ->
      %BookTarget{id: 1, media_kind: :audiobook, status: :monitored, preferred_language: language}
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
             AudiobookManualSearchComponent.update(
               %{id: "ms", target: target.("fr"), work: work},
               loaded
             )

    assert updated.assigns.state == :loading
    assert updated.assigns.results == %{accepted: [], rejected: [], complete?: true}
  end

  test "an unrelated re-render (same language) keeps the loaded results as they are" do
    target = %BookTarget{
      id: 1,
      media_kind: :audiobook,
      status: :monitored,
      preferred_language: "en"
    }

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
             AudiobookManualSearchComponent.update(
               %{id: "ms", target: target, work: work},
               loaded
             )

    assert updated.assigns.state == :loaded
    assert updated.assigns.results == results
  end
end
