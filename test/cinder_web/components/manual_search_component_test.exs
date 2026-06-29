# A minimal host LiveView so the component's grab event actually runs (render_component/2 only
# renders, it doesn't process events). It forwards the {:manual_grab, …} the component sends to
# its parent on to the test pid, so we can assert which release was resolved from a click.
defmodule CinderWeb.ManualSearchHostLive do
  @moduledoc false
  use Phoenix.LiveView

  alias Cinder.Acquisition.Release
  alias Cinder.Catalog.Movie

  # Two releases with an IDENTICAL title but distinct download_urls — the multi-tracker dupe
  # case FIX 3 guards: a title match could resolve the wrong one.
  @results [
    {%Release{
       title: "Same Title",
       resolution: "1080p",
       protocol: :torrent,
       download_url: "url-a"
     }, :ok},
    {%Release{title: "Same Title", resolution: "720p", protocol: :torrent, download_url: "url-b"},
     :ok}
  ]

  @impl true
  def mount(_params, %{"test_pid" => pid}, socket),
    do: {:ok, assign(socket, test_pid: pid, results: @results)}

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component
      module={CinderWeb.ManualSearchComponent}
      id="ms"
      mode={:movie}
      target={%Movie{id: 1, status: :requested, imdb_id: "tt1", title: "M"}}
      results={@results}
    />
    """
  end

  @impl true
  def handle_info({:manual_grab, _mode, _target, release}, socket) do
    send(socket.assigns.test_pid, {:grabbed, release})
    {:noreply, socket}
  end
end

defmodule CinderWeb.ManualSearchComponentTest do
  use CinderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Cinder.Acquisition.Release
  alias Cinder.Catalog.{Movie, Series}
  alias CinderWeb.ManualSearchComponent

  # A pre-seeded `results:` assign makes update/2 skip the async indexer fetch, so the panel can be
  # rendered and asserted without a host LiveView. The async path is covered in Tasks 12/13.
  defp render_panel(assigns) do
    render_component(ManualSearchComponent, Map.merge(%{id: "ms"}, assigns))
  end

  test "lists each release with its resolution, language and rejection reason" do
    html =
      render_panel(%{
        mode: :movie,
        target: %Movie{id: 1, status: :requested, imdb_id: "tt1", title: "M"},
        results: [
          {%Release{title: "Pick 1080p", resolution: "1080p", protocol: :torrent, language: "en"},
           :ok},
          {%Release{title: "Huge 2160p", resolution: "2160p", protocol: :torrent, language: "fr"},
           {:rejected, :out_of_band}}
        ]
      })

    assert html =~ "Pick 1080p"
    assert html =~ "Huge 2160p"
    assert html =~ "1080p"
    assert html =~ "en"
    assert html =~ "Grab"
    assert html =~ "outside size band"
  end

  test "a non-available movie grabs directly (phx-click=grab)" do
    html =
      render_panel(%{
        mode: :movie,
        target: %Movie{id: 1, status: :requested, imdb_id: "tt1", title: "M"},
        results: [{%Release{title: "Direct grab", resolution: "1080p", protocol: :torrent}, :ok}]
      })

    assert html =~ ~s(phx-click="grab")
    refute html =~ ~s(phx-click="ask_replace")
  end

  test "an available movie routes through the replace confirm (phx-click=ask_replace)" do
    html =
      render_panel(%{
        mode: :movie,
        target: %Movie{id: 1, status: :available, imdb_id: "tt1", title: "M"},
        results: [{%Release{title: "Replacement", resolution: "1080p", protocol: :torrent}, :ok}]
      })

    assert html =~ ~s(phx-click="ask_replace")
    refute html =~ ~s(phx-click="grab")
  end

  test "a wrong-protocol release is listed but not grabbable" do
    html =
      render_panel(%{
        mode: :movie,
        target: %Movie{id: 1, status: :requested, imdb_id: "tt1", title: "M"},
        results: [
          {%Release{title: "Usenet only", resolution: "1080p", protocol: :usenet},
           {:rejected, :wrong_protocol}}
        ]
      })

    assert html =~ "Usenet only"
    assert html =~ "no client for protocol"
    # No grab control rendered for an ungrabbable release.
    refute html =~ "phx-value-index"
  end

  # FIX 1: an empty TV indexer result is "no releases found", not "season complete". The component
  # can't tell the two apart, so it must not claim the season is complete (the parent only offers
  # manual search for seasons that still have wanted episodes).
  test "a TV season with no results says no releases found (not season complete)" do
    html =
      render_panel(%{
        mode: :tv,
        target: %Series{id: 1, title: "S"},
        season_number: 1,
        results: []
      })

    assert html =~ "No releases found."
    refute html =~ "All episodes present"
    refute html =~ "Replacing existing TV files"
  end

  # FIX 4: the Grab button carries phx-disable-with so a fast double-click can't fire two grabs
  # (two Download.grab calls → one orphaned download) before the list reloads.
  test "the Grab button is guarded against a double-click (phx-disable-with)" do
    html =
      render_panel(%{
        mode: :movie,
        target: %Movie{id: 1, status: :requested, imdb_id: "tt1", title: "M"},
        results: [{%Release{title: "Grabbable", resolution: "1080p", protocol: :torrent}, :ok}]
      })

    assert html =~ "phx-disable-with"
  end

  # FIX 3: two listed releases can share an identical title (multi-tracker Prowlarr dupes), so
  # the grab handler must resolve by a unique key (the list index), not by title — otherwise the
  # wrong release (different protocol/size/download_url) could be grabbed.
  test "two same-title releases resolve to the clicked one, not the first title match", %{
    conn: conn
  } do
    {:ok, lv, _html} =
      live_isolated(conn, CinderWeb.ManualSearchHostLive, session: %{"test_pid" => self()})

    # The second release (index 1) shares its title with the first but carries url-b.
    lv |> element("button[phx-value-index='1']", "Grab") |> render_click()
    assert_receive {:grabbed, %Release{download_url: "url-b"}}

    # And the first (index 0) resolves to its own distinct release.
    lv |> element("button[phx-value-index='0']", "Grab") |> render_click()
    assert_receive {:grabbed, %Release{download_url: "url-a"}}
  end
end
