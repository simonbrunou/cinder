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
    %{
      release: %Release{
        title: "Same Title",
        resolution: "1080p",
        protocol: :torrent,
        download_url: "url-a"
      },
      verdict: :ok,
      audio: nil
    },
    %{
      release: %Release{
        title: "Same Title",
        resolution: "720p",
        protocol: :torrent,
        download_url: "url-b"
      },
      verdict: :ok,
      audio: nil
    }
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

  alias Cinder.Acquisition.IndexerSource.Report
  alias Cinder.Acquisition.Release
  alias Cinder.Catalog.{Movie, Series}
  alias CinderWeb.ManualSearchComponent
  alias Phoenix.LiveView.Socket

  # A pre-seeded `results:` assign makes update/2 skip the async indexer fetch, so the panel can be
  # rendered and asserted without a host LiveView. The async path is covered in Tasks 12/13.
  defp render_panel(assigns) do
    render_component(ManualSearchComponent, Map.merge(%{id: "ms"}, assigns))
  end

  # A row as `Cinder.Acquisition.ReleaseJudge` builds it; the panel reads these three keys.
  defp row(release, verdict \\ :ok, audio \\ nil),
    do: %{release: release, verdict: verdict, audio: audio}

  test "lists each release with its resolution, language and rejection reason" do
    html =
      render_panel(%{
        mode: :movie,
        target: %Movie{id: 1, status: :requested, imdb_id: "tt1", title: "M"},
        results: [
          row(
            %Release{
              title: "Pick 1080p",
              resolution: "1080p",
              protocol: :torrent,
              language: "en"
            },
            :ok
          ),
          row(
            %Release{
              title: "Huge 2160p",
              resolution: "2160p",
              protocol: :torrent,
              language: "fr"
            },
            {:rejected, :out_of_band}
          )
        ]
      })

    assert html =~ "Pick 1080p"
    assert html =~ "Huge 2160p"
    assert html =~ "1080p"
    assert html =~ "en"
    assert html =~ "Grab"
    assert html =~ "outside size band"
  end

  # #900: the panel states the judge's coverage fact and never re-derives it from the release.
  test "a row the judge marks as covering no wanted episode says so, beside its verdict" do
    release = %Release{
      title: "Show S01 1080p",
      resolution: "1080p",
      protocol: :torrent,
      season: 1
    }

    render_row = fn covers_wanted, verdict ->
      render_panel(%{
        mode: :tv,
        target: %Series{id: 1, title: "Show", media_profile: :standard},
        season_number: 1,
        results: [Map.put(row(release, verdict), :covers_wanted, covers_wanted)]
      })
    end

    html = render_row.(false, :ok)
    assert html =~ "covers no wanted episode"
    assert html =~ "Grab"
    refute html =~ "text-warning"

    html = render_row.(false, {:rejected, :out_of_band})
    assert html =~ "covers no wanted episode"
    assert html =~ "outside size band"
    assert html =~ "Grab"

    refute render_row.(true, :ok) =~ "covers no wanted episode"
    refute render_row.(nil, :ok) =~ "covers no wanted episode"

    refute render_panel(%{
             mode: :tv,
             target: %Series{id: 1, title: "Show"},
             season_number: 1,
             results: [row(release)]
           }) =~ "covers no wanted episode"
  end

  test "every row badges its language against the title's audio pick, untagged included" do
    html =
      render_panel(%{
        mode: :movie,
        target: %Movie{
          id: 1,
          status: :requested,
          imdb_id: "tt1",
          title: "Film",
          preferred_language: "french",
          original_language: "en"
        },
        results: [
          row(
            %Release{
              title: "Le film",
              resolution: "1080p",
              protocol: :torrent,
              language: "FRENCH"
            },
            :ok,
            :match
          ),
          row(
            %Release{title: "The film", resolution: "1080p", protocol: :torrent},
            :ok,
            :mismatch
          )
        ]
      })

    # The untagged row is English by scene convention, so a strict french pick drops it and the
    # badge says so; an untagged row with no badge would read as "no opinion".
    assert html =~ "untagged"
    assert html =~ "badge-warning"
    assert html =~ "Doesn&#39;t match this title&#39;s audio pick"
    assert html =~ "Matches this title&#39;s audio pick"
    # Not colour alone: the mismatch carries an icon and screen-reader text (WCAG 1.4.1).
    assert html =~ "hero-exclamation-triangle-mini"
    assert html =~ "sr-only"
  end

  # `:assumed` is the release judge's word for an untagged release a movie or season pool kept
  # under a soft pick (#191, #882): not a match, but not a rejection either. Which rows carry which
  # fact is the judge's to decide (`Cinder.Acquisition.ReleaseJudgeTest`); the panel only says it.
  test "an assumed release says why it is kept without a warning" do
    targets = [
      {:movie, %Movie{id: 1, status: :requested, imdb_id: "tt1", title: "Guru"}},
      {:tv, %Series{id: 1, title: "Guru", media_profile: :standard}}
    ]

    for {mode, target} <- targets do
      html =
        render_panel(%{
          mode: mode,
          target: target,
          results: [
            row(%Release{title: "Guru.S01.1080p.WEB.H264-FW", protocol: :torrent}, :ok, :assumed)
          ]
        })

      assert html =~ "untagged", inspect(mode)
      refute html =~ "badge-warning", inspect(mode)
      refute html =~ "Doesn&#39;t match", inspect(mode)
      assert html =~ "assumed to be the original audio", inspect(mode)
    end
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
        results: [row(%Release{title: "Whatever", resolution: "1080p", protocol: :torrent}, :ok)]
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
        results: [
          row(%Release{title: "Direct grab", resolution: "1080p", protocol: :torrent}, :ok)
        ]
      })

    assert html =~ ~s(phx-click="grab")
    refute html =~ ~s(phx-click="ask_replace")
  end

  test "an available movie routes through the replace confirm (phx-click=ask_replace)" do
    html =
      render_panel(%{
        mode: :movie,
        target: %Movie{id: 1, status: :available, imdb_id: "tt1", title: "M"},
        results: [
          row(%Release{title: "Replacement", resolution: "1080p", protocol: :torrent}, :ok)
        ]
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
          row(
            %Release{title: "Usenet only", resolution: "1080p", protocol: :usenet},
            {:rejected, :wrong_protocol}
          )
        ]
      })

    assert html =~ "Usenet only"
    assert html =~ "no client for protocol"
    # No grab control rendered for an ungrabbable release.
    refute html =~ "phx-value-index"
  end

  test "a blocked-term verdict remains manually grabbable" do
    html =
      render_panel(%{
        mode: :movie,
        target: %Movie{id: 1, status: :requested, imdb_id: "tt1", title: "M"},
        results: [
          row(
            %Release{title: "Movie.CAM", resolution: "1080p", protocol: :torrent},
            {:rejected, :blocked_term}
          )
        ]
      })

    assert html =~ "contains a blocked term"
    assert html =~ ~s(phx-value-index="0")
  end

  test "Anime policy verdicts stay overridable while unsafe mappings are not grabbable" do
    html =
      render_panel(%{
        mode: :tv,
        target: %Series{id: 1, title: "Anime", media_profile: :anime},
        season_number: 0,
        results: [
          row(
            %Release{title: "Blocked", resolution: "1080p", protocol: :torrent},
            {:rejected, :blocked_anime_group}
          ),
          row(
            %Release{title: "Audio", resolution: "1080p", protocol: :torrent},
            {:rejected, :contradictory_audio}
          ),
          row(
            %Release{title: "Subtitles", resolution: "1080p", protocol: :torrent},
            {:rejected, :contradictory_subtitles}
          ),
          row(
            %Release{title: "Waiting", resolution: "1080p", protocol: :torrent},
            {:rejected, :awaiting_preferred_group}
          ),
          row(
            %Release{title: "Undated", resolution: "1080p", protocol: :torrent},
            {:rejected, :publication_time_required}
          ),
          row(
            %Release{title: "Unresolved", resolution: "1080p", protocol: :torrent},
            {:rejected, :unsafe_anime_mapping}
          ),
          row(
            %Release{title: "OVA", resolution: "1080p", protocol: :torrent},
            {:rejected, :special_release}
          )
        ]
      })

    assert html =~ "blocked anime group"
    assert html =~ "contradictory audio"
    assert html =~ "contradictory subtitles"
    assert html =~ "awaiting preferred group"
    assert html =~ "publication time required"
    assert html =~ "stable episode mapping required"
    assert html =~ "special, manual grab only"

    for index <- [0, 1, 2, 3, 4, 6], do: assert(html =~ ~s(phx-value-index="#{index}"))
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
        results: [row(old_release)],
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
          results: [row(%Release{title: "Ranked for the old target", protocol: :torrent}, :ok)],
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

    # "french" and "dual" resolve to the same strict target, so swapping between them changes no
    # verdict, badge or rank and the loaded results stand.
    assert {:ok, held} =
             ManualSearchComponent.update(
               assigns.(movie.("dual", "en")),
               loaded.(movie.("french", "en"))
             )

    assert held.assigns.state == :loaded

    # Same target, but a soft pick keeps untagged releases and falls back where a strict one
    # drops them: the badges come from the judged rows, so they have to be judged again.
    assert {:ok, rejudged} =
             ManualSearchComponent.update(
               assigns.(movie.("french", "fr")),
               loaded.(movie.("original", "fr"))
             )

    assert rejudged.assigns.state == :loading
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
        results: [row(%Release{title: "Grabbable", resolution: "1080p", protocol: :torrent}, :ok)]
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

  describe "what the search's report and error say (#1648)" do
    setup do
      # Asia/Tokyo is UTC+9 all year, so a household time differs from UTC's by a fixed amount.
      Cinder.ConfigCase.put_env(:household_timezone, "Asia/Tokyo")
      :ok
    end

    @movie %Movie{id: 1, status: :requested, imdb_id: "tt1", title: "M"}

    # The text of every element `selector` matches in `html`, whitespace collapsed.
    defp texts(html, selector) do
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))
    end

    # 14:35 on the household's today, and on the day after tomorrow, in Asia/Tokyo.
    defp tokyo_1435(days_from_today) do
      Cinder.Settings.household_date()
      |> Date.add(days_from_today)
      |> DateTime.new!(~T[14:35:00], "Asia/Tokyo")
    end

    defp report(entries, failed_calls \\ 0) do
      report =
        Enum.reduce(entries, Report.new(), fn {id, name, outcome}, acc ->
          Report.put(acc, {"native", id}, name, outcome)
        end)

      %{report | failed_calls: failed_calls}
    end

    test "each row shows its release's indexer name; a row with none shows nothing" do
      html =
        render_panel(%{
          mode: :movie,
          target: @movie,
          results: [
            row(%Release{title: "Named", protocol: :torrent, indexer_name: "NZBgeek"}),
            row(%Release{title: "Unnamed", protocol: :torrent, indexer_name: nil}),
            row(%Release{title: "Blank", protocol: :torrent, indexer_name: ""})
          ]
        })

      # Neither a nil nor a blank name renders an element.
      assert texts(html, "#ms li [data-indexer]") == ["NZBgeek"]
      assert [named, unnamed, _blank] = texts(html, "#ms li")
      assert named =~ "Named NZBgeek"
      refute unnamed =~ "NZBgeek"
    end

    test "a loaded panel names each failed or skipped indexer with its reason, in household time" do
      today = tokyo_1435(0)
      later = tokyo_1435(2)

      html =
        render_panel(%{
          mode: :movie,
          target: @movie,
          results: [row(%Release{title: "Found", protocol: :torrent})],
          report:
            report([
              {1, "One", {:failed, :timeout}},
              {2, "Two", {:skipped, {:backoff, DateTime.shift_zone!(today, "Etc/UTC")}}},
              {3, "Three", {:skipped, {:backoff, later}}},
              {4, "Answered", :asked}
            ])
        })

      later_text = CinderWeb.LiveHelpers.format_date(DateTime.to_date(later)) <> ", 14:35"

      assert texts(html, "#ms-unanswered") == [
               "Not every indexer answered: One (timed out), " <>
                 "Three (waiting until #{later_text}), Two (waiting until 14:35)."
             ]

      # A named failure alone is not the generic incomplete line.
      assert texts(html, "#ms-incomplete") == []
    end

    test "a report that counts a failed seam call shows the incomplete line" do
      html =
        render_panel(%{
          mode: :movie,
          target: @movie,
          results: [row(%Release{title: "Found", protocol: :torrent})],
          report: report([], 1)
        })

      assert texts(html, "#ms-incomplete") == [
               "Some indexers could not be reached; results may be incomplete."
             ]

      assert texts(html, "#ms-unanswered") == []
    end

    test "with the default empty report, neither line shows" do
      html =
        render_panel(%{
          mode: :movie,
          target: @movie,
          results: [row(%Release{title: "Found", protocol: :torrent})]
        })

      assert texts(html, "#ms li") != []
      assert texts(html, "#ms-incomplete") == []
      assert texts(html, "#ms-unanswered") == []
    end

    test "each search error renders its own text" do
      no_answer = report([{1, "One", {:failed, {:http_status, 503}}}])

      table = [
        {{:no_indexer_answered, no_answer}, "No indexer answered. Try again."},
        {:no_indexers, "No indexer is enabled. Add one in Settings."},
        {{:indexers_backing_off, tokyo_1435(0)}, "Every indexer is waiting until 14:35."},
        {{:prowlarr_status, 500}, "Couldn't reach Prowlarr. Try again."},
        {{:anime_policy, :original_language_required}, "The search failed. Try again."},
        {{:exit, :killed}, "The search failed. Try again."}
      ]

      for {reason, text} <- table do
        html = render_panel(%{mode: :movie, target: @movie, state: :error, error: reason})

        assert texts(html, "#ms-error") == [text], "reason #{inspect(reason)}"
      end
    end

    test "a no-answer error shows the line from the report it carries" do
      reason = {:no_indexer_answered, report([{1, "One", {:failed, {:http_status, 503}}}])}
      html = render_panel(%{mode: :movie, target: @movie, state: :error, error: reason})

      assert texts(html, "#ms-unanswered") == ["Not every indexer answered: One (HTTP 503)."]

      other = render_panel(%{mode: :movie, target: @movie, state: :error, error: :no_indexers})
      assert texts(other, "#ms-error") != []
      assert texts(other, "#ms-unanswered") == []
    end

    test "handle_async keeps the rows, the report and the error reason" do
      socket = %Socket{assigns: %{__changed__: %{}, state: :loading, results: []}}
      rows = [row(%Release{title: "Found", protocol: :torrent})]
      answered = report([{1, "One", {:failed, :timeout}}])

      assert {:noreply, loaded} =
               ManualSearchComponent.handle_async(
                 :search,
                 {:ok, {:ok, rows, answered}},
                 socket
               )

      assert %{state: :loaded, results: ^rows, report: ^answered, error: nil} = loaded.assigns

      assert {:noreply, failed} =
               ManualSearchComponent.handle_async(:search, {:ok, {:error, :no_indexers}}, loaded)

      assert %{state: :error, error: :no_indexers} = failed.assigns
      assert failed.assigns.report == Report.new()

      assert {:noreply, exited} =
               ManualSearchComponent.handle_async(:search, {:exit, :killed}, loaded)

      assert %{state: :error, error: {:exit, :killed}} = exited.assigns
      assert exited.assigns.report == Report.new()
    end

    test "a new search context drops the old report and error" do
      stale = %Socket{
        assigns: %{
          __changed__: %{},
          id: "ms",
          mode: :movie,
          target: @movie,
          state: :loaded,
          results: [row(%Release{title: "Old", protocol: :torrent})],
          report: report([{1, "One", {:failed, :timeout}}], 1),
          error: :no_indexers,
          confirming: nil
        }
      }

      moved = %Movie{@movie | id: 2}

      assert {:ok, updated} =
               ManualSearchComponent.update(%{id: "ms", mode: :movie, target: moved}, stale)

      assert updated.assigns.state == :loading
      assert updated.assigns.report == Report.new()
      assert updated.assigns.error == nil
    end
  end

  describe "the live region around the search's lines (#1722)" do
    defp query(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

    defp attribute(html, selector, name),
      do: html |> query(selector) |> LazyHTML.attribute(name)

    # The child nodes of the elements `selector` matches, in order, each as trimmed HTML, with
    # blank text nodes and comments left out.
    defp child_nodes(html, selector) do
      html
      |> query(selector)
      |> LazyHTML.child_nodes()
      |> Enum.map(&(&1 |> LazyHTML.to_html() |> String.trim()))
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "<!--")))
    end

    test "a loading panel already holds the region, with the loading line in it" do
      html = render_panel(%{mode: :movie, target: @movie, state: :loading})

      assert Enum.count(query(html, "#ms-status")) == 1
      assert attribute(html, "#ms-status", "role") == ["status"]
      assert attribute(html, "#ms-status", "aria-live") == ["polite"]
      assert texts(html, "#ms-status") == ["Searching releases…"]
    end

    test "the error line sits in the region, after an icon screen readers skip" do
      html = render_panel(%{mode: :movie, target: @movie, state: :error, error: :no_indexers})

      assert Enum.count(query(html, "#ms-status #ms-error")) == 1
      assert texts(html, "#ms-error") == ["No indexer is enabled. Add one in Settings."]

      assert attribute(html, "#ms-error .hero-exclamation-circle", "aria-hidden") == ["true"]
      assert [icon, text] = child_nodes(html, "#ms-error")
      assert icon =~ "hero-exclamation-circle"
      assert text == "No indexer is enabled. Add one in Settings."
    end

    test "a no-answer error puts its unanswered line in the region too" do
      reason =
        {:no_indexer_answered,
         Report.put(Report.new(), {"native", 1}, "One", {:failed, {:http_status, 503}})}

      html = render_panel(%{mode: :movie, target: @movie, state: :error, error: reason})

      assert Enum.count(query(html, "#ms-status #ms-error")) == 1
      assert Enum.count(query(html, "#ms-status #ms-unanswered")) == 1
    end

    test "a loaded panel's incomplete and unanswered lines sit in the region" do
      report =
        Report.new()
        |> Report.put({"native", 1}, "One", {:failed, :timeout})
        |> Map.put(:failed_calls, 1)

      html =
        render_panel(%{
          mode: :movie,
          target: @movie,
          results: [row(%Release{title: "Found", protocol: :torrent})],
          report: report
        })

      assert Enum.count(query(html, "#ms-status #ms-incomplete")) == 1
      assert Enum.count(query(html, "#ms-status #ms-unanswered")) == 1
    end

    test "a loaded panel with no results says so in the region" do
      html = render_panel(%{mode: :movie, target: @movie, results: []})

      assert texts(html, "#ms-status") == ["No releases found."]
    end

    test "the rows and their Grab buttons sit outside the region" do
      html =
        render_panel(%{
          mode: :movie,
          target: @movie,
          results: [row(%Release{title: "Found", protocol: :torrent})]
        })

      assert Enum.count(query(html, "#ms-status")) == 1
      assert Enum.count(query(html, "#ms li")) == 1
      assert Enum.count(query(html, "#ms li button")) == 1
      assert Enum.empty?(query(html, "#ms-status li"))
      assert Enum.empty?(query(html, "#ms-status button"))
      assert texts(html, "#ms-status") == [""]
    end
  end
end
