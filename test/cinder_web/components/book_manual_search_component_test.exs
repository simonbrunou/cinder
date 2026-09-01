# A minimal host LiveView so the component's grab event actually runs (render_component/2 only
# renders, it doesn't process events). It forwards the {:manual_grab, …} the component sends to
# its parent on to the test pid, mirroring CinderWeb.ManualSearchHostLive for movies/TV.
defmodule CinderWeb.BookManualSearchHostLive do
  @moduledoc false
  use Phoenix.LiveView

  alias Cinder.Acquisition.BookRelease
  alias Cinder.Books.BookTarget

  @results %{
    accepted: [
      {%BookRelease{title: "Author - Title (EPUB)", download_url: "url-a", protocol: :torrent},
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

  alias Cinder.Acquisition.{BookRelease, BookScorer}
  alias Cinder.Books.BookTarget
  alias CinderWeb.BookManualSearchComponent

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
    do: BookRelease.new(Map.merge(%{title: title, download_url: "u", protocol: :torrent}, attrs))

  defp evidence(attrs \\ %{}),
    do:
      Map.merge(
        %{format: :epub, formats: [:epub], language: nil, retail?: false, size: 2_000_000},
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

    assert_receive {:grabbed, %BookRelease{download_url: "url-a"}}
  end
end
