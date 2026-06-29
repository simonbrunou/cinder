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
    refute html =~ "phx-value-title"
  end

  test "a TV season with no results says replacing existing files isn't supported yet" do
    html =
      render_panel(%{
        mode: :tv,
        target: %Series{id: 1, title: "S"},
        season_number: 1,
        results: []
      })

    assert html =~ "Replacing existing TV files"
    refute html =~ "No releases found."
  end
end
