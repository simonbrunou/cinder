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
  alias Phoenix.LiveView.Socket

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

  test "every row badges its language against the title's audio pick, untagged included" do
    html =
      render_panel(%{
        mode: :movie,
        target: %Movie{
          id: 1,
          status: :requested,
          imdb_id: "tt1",
          title: "M",
          preferred_language: "french",
          original_language: "en"
        },
        results: [
          {%Release{
             title: "Le film",
             resolution: "1080p",
             protocol: :torrent,
             language: "FRENCH"
           }, :ok},
          {%Release{title: "The film", resolution: "1080p", protocol: :torrent}, :ok}
        ]
      })

    # The untagged row is English by scene convention, so it fails a STRICT french pick (which
    # `Language.keep?/3` really does drop) and says so; before this it rendered no badge at all
    # and read as "no opinion".
    assert html =~ "untagged"
    assert html =~ "badge-warning"
    assert html =~ "Doesn&#39;t match this title&#39;s audio pick"
    assert html =~ "Matches this title&#39;s audio pick"
    # Not colour alone: the mismatch carries an icon and screen-reader text (WCAG 1.4.1).
    assert html =~ "hero-exclamation-triangle-mini"
    assert html =~ "sr-only"
  end

  # The gap between "the tag doesn't equal the target" and "the sweep would reject it": under a
  # SOFT "original" pick `movie_pool/2` passes `keep_untagged: true` and `Language.keep?/3` KEEPS
  # untagged releases (issue #191 — non-English groups publish original audio with a bare name).
  # Badging those a mismatch would accuse the rows the sweep is built to accept.
  test "an untagged release under a soft original pick is not accused of mismatching" do
    html =
      render_panel(%{
        mode: :movie,
        target: %Movie{
          id: 1,
          status: :requested,
          imdb_id: "tt1",
          title: "Guru",
          preferred_language: "original",
          original_language: "fr"
        },
        results: [{%Release{title: "Guru.2025.1080p.WEB.H264-FW", protocol: :torrent}, :ok}]
      })

    assert html =~ "untagged"
    refute html =~ "badge-warning"
    refute html =~ "Doesn&#39;t match"
    assert html =~ "assumed to be the original audio"
  end

  # `keep_untagged: true` is movie-only (`movie_pool/2`); the TV pool drops untagged rows, so the
  # same release that reads ":assumed" on a movie must read as a mismatch on a season panel.
  test "an untagged release on a TV season panel is a mismatch, not an assumption" do
    html =
      render_panel(%{
        mode: :tv,
        target: %Series{
          id: 1,
          title: "Série",
          preferred_language: "original",
          original_language: "fr"
        },
        season_number: 1,
        results: [
          {%Release{title: "Serie.S01.FRENCH", protocol: :torrent, language: "FRENCH"}, :ok},
          {%Release{title: "Serie.S01.1080p", protocol: :torrent}, :ok}
        ]
      })

    assert html =~ "badge-warning"
    assert html =~ "Doesn&#39;t match this title&#39;s audio pick"
    refute html =~ "assumed to be the original audio"
  end

  # An original language with no entry in the parser's tag registry ("is") is still satisfied by
  # MULTI, so the pool is non-empty and the sweep genuinely rejects the FRENCH row — the panel has
  # to say so. Mirroring `Language.filter/4` gets this right without a special case.
  test "an unmapped original language still flags what the pool actually drops" do
    html =
      render_panel(%{
        mode: :tv,
        target: %Series{
          id: 1,
          title: "Hérbergið",
          preferred_language: "original",
          original_language: "is"
        },
        season_number: 1,
        results: [
          {%Release{title: "Multi", protocol: :torrent, language: "MULTI"}, :ok},
          {%Release{title: "Wrong", protocol: :torrent, language: "FRENCH"}, :ok}
        ]
      })

    assert html =~ "badge-warning"
    assert html =~ "Doesn&#39;t match this title&#39;s audio pick"
    assert html =~ "Matches this title&#39;s audio pick"
  end

  # …but when a SOFT pick would drop the whole list, `language_pool/4` falls back to the unfiltered
  # candidates, so the sweep has no opinion and neither should the panel. A uniform warning on
  # every row carries no information and asserts a rejection that never happens.
  test "a soft pick that would drop everything flags nothing" do
    html =
      render_panel(%{
        mode: :tv,
        target: %Series{
          id: 1,
          title: "Hérbergið",
          preferred_language: "original",
          original_language: "is"
        },
        season_number: 1,
        results: [
          {%Release{title: "One", protocol: :torrent, language: "FRENCH"}, :ok},
          {%Release{title: "Two", protocol: :torrent, language: "GERMAN"}, :ok}
        ]
      })

    refute html =~ "badge-warning"
    refute html =~ "audio pick"
  end

  # A STRICT pick has no such fallback — it parks — so it flags every row even when none survive.
  test "a strict pick that drops everything still flags every row" do
    html =
      render_panel(%{
        mode: :movie,
        target: %Movie{
          id: 1,
          status: :requested,
          imdb_id: "tt1",
          title: "M",
          preferred_language: "french",
          original_language: "en"
        },
        results: [{%Release{title: "Only.English", protocol: :torrent, language: "ENGLISH"}, :ok}]
      })

    assert html =~ "badge-warning"
    assert html =~ "Doesn&#39;t match this title&#39;s audio pick"
  end

  test "the audio-pick badge stays neutral when no pick is in force" do
    html =
      render_panel(%{
        mode: :movie,
        target: %Movie{
          id: 1,
          status: :requested,
          imdb_id: "tt1",
          title: "M",
          preferred_language: "any"
        },
        results: [{%Release{title: "Whatever", resolution: "1080p", protocol: :torrent}, :ok}]
      })

    assert html =~ "untagged"
    refute html =~ "badge-warning"
    refute html =~ "audio pick"
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

  test "Anime policy verdicts stay overridable while unsafe mappings are not grabbable" do
    html =
      render_panel(%{
        mode: :tv,
        target: %Series{id: 1, title: "Anime", media_profile: :anime},
        season_number: 0,
        results: [
          {%Release{title: "Blocked", resolution: "1080p", protocol: :torrent},
           {:rejected, :blocked_anime_group}},
          {%Release{title: "Audio", resolution: "1080p", protocol: :torrent},
           {:rejected, :contradictory_audio}},
          {%Release{title: "Subtitles", resolution: "1080p", protocol: :torrent},
           {:rejected, :contradictory_subtitles}},
          {%Release{title: "Waiting", resolution: "1080p", protocol: :torrent},
           {:rejected, :awaiting_preferred_group}},
          {%Release{title: "Undated", resolution: "1080p", protocol: :torrent},
           {:rejected, :publication_time_required}},
          {%Release{title: "Unresolved", resolution: "1080p", protocol: :torrent},
           {:rejected, :unsafe_anime_mapping}}
        ]
      })

    assert html =~ "blocked anime group"
    assert html =~ "contradictory audio"
    assert html =~ "contradictory subtitles"
    assert html =~ "awaiting preferred group"
    assert html =~ "publication time required"
    assert html =~ "stable episode mapping required"

    for index <- 0..4, do: assert(html =~ ~s(phx-value-index="#{index}"))
    refute html =~ ~s(phx-value-index="5")
  end

  test "switching from an Anime target to Standard clears stale release state" do
    old_target = %Series{id: 1, title: "Anime", media_profile: :anime}

    old_release = %Release{
      title: "Anime whole-series result",
      episodes: nil,
      mapping_snapshot: %{"version" => 2}
    }

    socket = %Socket{
      assigns: %{
        __changed__: %{},
        id: "ms",
        mode: :tv,
        target: old_target,
        season_number: 0,
        state: :loaded,
        results: [{old_release, :ok}],
        confirming: "0"
      }
    }

    new_assigns = %{
      id: "ms",
      mode: :tv,
      target: %Series{id: 2, title: "Standard", media_profile: :standard},
      season_number: 1
    }

    assert {:ok, updated} = ManualSearchComponent.update(new_assigns, socket)
    assert updated.assigns.state == :loading
    assert updated.assigns.results == []
    assert updated.assigns.confirming == nil
  end

  # A TMDB refresh can move `original_language` under an unchanged "original" pick, which moves the
  # audio target the results were ranked against. The context holds the RESOLVED target so that
  # restarts the search — otherwise the badges flip and the stale ordering stays.
  test "a metadata refresh that moves the resolved audio target restarts the search" do
    movie = fn pick, original ->
      %Movie{
        id: 1,
        status: :requested,
        imdb_id: "tt1",
        title: "M",
        preferred_language: pick,
        original_language: original
      }
    end

    loaded = fn target ->
      %Socket{
        assigns: %{
          __changed__: %{},
          id: "ms",
          mode: :movie,
          target: target,
          state: :loaded,
          results: [{%Release{title: "Ranked for the old target", protocol: :torrent}, :ok}],
          confirming: "0"
        }
      }
    end

    assigns = fn target -> %{id: "ms", mode: :movie, target: target} end

    refreshed = movie.("original", "ja")

    assert {:ok, updated} =
             ManualSearchComponent.update(assigns.(refreshed), loaded.(movie.("original", "en")))

    assert updated.assigns.state == :loading
    assert updated.assigns.results == []
    assert updated.assigns.confirming == nil
    assert updated.assigns.audio_target == "ja"

    # "french" and "dual" resolve to the same target, so swapping between them re-ranks nothing
    # and the loaded results stand.
    assert {:ok, held} =
             ManualSearchComponent.update(
               assigns.(movie.("dual", "en")),
               loaded.(movie.("french", "en"))
             )

    assert held.assigns.state == :loaded
    assert held.assigns.audio_target == "fr"
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
