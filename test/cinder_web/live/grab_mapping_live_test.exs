defmodule CinderWeb.GrabMappingLiveTest do
  use CinderWeb.ConnCase, async: false

  import Cinder.AccountsFixtures
  import Cinder.CatalogFixtures
  import Mox
  import Phoenix.LiveViewTest

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Grab}
  alias Cinder.Repo

  setup :register_and_log_in_admin
  setup :set_mox_global

  test "the mapping route requires an authenticated admin", %{conn: _conn} do
    grab = held_mapping_fixture!().grab
    path = "/activity/grabs/#{grab.id}/mapping"

    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), path)

    conn = build_conn() |> log_in_user(user_fixture())
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, path)
  end

  test "missing, standard, and no-longer-held grabs redirect to Activity", %{conn: conn} do
    fixture = held_mapping_fixture!()

    resolved =
      fixture.grab |> Grab.mapping_changeset(%{mapping_status: :resolved}) |> Repo.update!()

    standard_episode = episode_fixture(season_fixture(series_fixture()))

    assert {:ok, standard} =
             Catalog.create_grab("standard-mapping-route", :torrent, [standard_episode.id])

    for id <- [System.unique_integer([:positive]) + 1_000_000_000, standard.id, resolved.id] do
      assert {:error, {kind, %{to: "/activity", flash: flash}}} =
               live(conn, "/activity/grabs/#{id}/mapping")

      assert kind in [:redirect, :live_redirect]
      assert flash["error"] == "That mapping no longer needs attention."
    end
  end

  test "renders relative evidence, same-series choices, and no absolute content path", %{
    conn: conn
  } do
    %{grab: grab, alternate: alternate, original: original, target: target} =
      held_mapping_fixture!()

    foreign = episode_fixture(season_fixture(series_fixture()), episode_number: 9)

    {:ok, view, _html} = live(conn, "/activity/grabs/#{grab.id}/mapping")

    assert has_element?(view, "#mapping-release", "Frieren.01-02.1080p-GROUP")
    assert has_element?(view, "#mapping-original-targets", to_string(original.id))
    assert has_element?(view, "#mapping-current-targets", "S01E01")
    assert has_element?(view, "#mapping-file-0", "Frieren - 11-12.mkv")
    assert has_element?(view, "#mapping-file-0", "device 1")
    assert has_element?(view, "#mapping-file-0", "Absolute 11, 12")
    assert has_element?(view, "#mapping-file-0", "candidate #{target.id}")
    assert has_element?(view, "#mapping-file-0", "candidate #{alternate.id}")
    assert has_element?(view, "#mapping-file-0-source", "Automatic")
    assert has_element?(view, "#mapping-file-0 [data-resolution]", "Ambiguous")
    assert has_element?(view, "#mapping-file-0 [data-candidate-set]", to_string(target.id))
    assert has_element?(view, "#mapping-file-0 [data-candidate-set]", to_string(alternate.id))
    assert has_element?(view, "#mapping-file-0 [data-provenance]", "Manual")
    assert has_element?(view, "#mapping-file-0 [data-provenance]", "one")
    assert has_element?(view, "#mapping-file-0 [data-provenance]", "a")
    assert has_element?(view, "#mapping-issue", "Unresolved file")
    assert has_element?(view, "#mapping-issue", "candidate #{target.id}")
    assert has_element?(view, "#mapping-issue", "candidate #{alternate.id}")
    assert has_element?(view, "#mapping-target-delta")
    assert has_element?(view, "#mapping-file-0-episode-#{target.id}")
    assert has_element?(view, "#mapping-target-episode-#{original.id}")
    assert has_element?(view, "#mapping-target-episode-#{target.id}")
    refute has_element?(view, "#mapping-file-0-episode-#{foreign.id}")

    html = render(view)
    refute html =~ "/srv/downloads/anime"
    refute html =~ grab.content_path
  end

  test "assign and ignore save exact integer IDs and redirect to Activity", %{conn: conn} do
    %{grab: grab, original: original, target: target} =
      held_mapping_fixture!(target_monitored: false)

    {:ok, view, _html} = live(conn, "/activity/grabs/#{grab.id}/mapping")

    params = %{
      "mapping" => %{
        "files" => %{
          "0" => %{
            "relative_path" => "Frieren - 11-12.mkv",
            "action" => "assign",
            "episode_ids" => [to_string(target.id)]
          },
          "1" => %{"relative_path" => "Extras/Frieren - NCOP.mkv", "action" => "ignore"}
        },
        "target_episode_ids" => [to_string(target.id)],
        "monitor_episode_ids" => [to_string(target.id)]
      }
    }

    view |> form("#mapping-form", params) |> render_submit()
    assert_redirect(view, "/activity")

    persisted = Repo.get!(Grab, grab.id)
    assert persisted.mapping_status == :resolved
    assert persisted.manual_mapping_overrides["target_episode_ids"] == [target.id]
    assert persisted.manual_mapping_overrides["monitor_episode_ids"] == [target.id]

    files = persisted.manual_mapping_overrides["files"]
    assigned = Enum.find(files, &(&1["action"] == "assign"))
    ignored = Enum.find(files, &(&1["action"] == "ignore"))
    assert assigned["relative_path"] == "Frieren - 11-12.mkv"
    assert assigned["episode_ids"] == [target.id]
    refute Map.has_key?(assigned, "content_path")
    refute Map.has_key?(assigned, "evidence")
    assert ignored["relative_path"] == "Extras/Frieren - NCOP.mkv"
    assert ignored["action"] == "ignore"
    refute Map.has_key?(ignored, "episode_ids")
    assert Repo.get!(Episode, original.id).grab_id == nil
    assert Repo.get!(Episode, target.id).grab_id == grab.id
    assert Repo.get!(Episode, target.id).monitored
  end

  test "unknown client keys never enter the persisted recovery document", %{conn: conn} do
    %{grab: grab, target: target} = held_mapping_fixture!()
    {:ok, view, _html} = live(conn, "/activity/grabs/#{grab.id}/mapping")

    %{"mapping" => mapping} = save_params(target.id)

    forged =
      mapping
      |> put_in(["files", "0", "content_path"], "/forged/path")
      |> put_in(["files", "0", "evidence"], %{"forged" => true})
      |> Map.put("unknown", "ignored")

    render_submit(view, "save_and_retry", %{"mapping" => forged})

    persisted = Repo.get!(Grab, grab.id)
    assigned = Enum.find(persisted.manual_mapping_overrides["files"], &(&1["action"] == "assign"))
    refute Map.has_key?(assigned, "content_path")
    refute Map.has_key?(assigned, "evidence")
    refute Map.has_key?(persisted.manual_mapping_overrides, "unknown")
  end

  test "malformed IDs show a form error without changing the held grab", %{conn: conn} do
    %{grab: grab} = held_mapping_fixture!()
    {:ok, view, _html} = live(conn, "/activity/grabs/#{grab.id}/mapping")

    render_submit(view, "save_and_retry", %{
      "mapping" => %{
        "files" => %{
          "0" => %{
            "relative_path" => "Frieren - 11-12.mkv",
            "action" => "assign",
            "episode_ids" => ["not-an-id"]
          }
        },
        "target_episode_ids" => ["not-an-id"],
        "monitor_episode_ids" => []
      }
    })

    assert has_element?(view, "#mapping-form-error", "The mapping could not be saved.")
    assert Repo.get!(Grab, grab.id).mapping_status == :needs_mapping
  end

  test "a stale save stays on the page with an error", %{conn: conn} do
    %{grab: grab, target: target} = held_mapping_fixture!()
    {:ok, view, _html} = live(conn, "/activity/grabs/#{grab.id}/mapping")
    grab |> Grab.mapping_changeset(%{mapping_status: :resolved}) |> Repo.update!()

    render_submit(view, "save_and_retry", save_params(target.id))

    assert has_element?(view, "#mapping-form-error", "The mapping could not be saved.")
    assert has_element?(view, "#mapping-release")
  end

  test "a series update redirects when the held mapping was resolved elsewhere", %{conn: conn} do
    %{grab: grab, series: series} = held_mapping_fixture!()
    {:ok, view, _html} = live(conn, "/activity/grabs/#{grab.id}/mapping")
    grab |> Grab.mapping_changeset(%{mapping_status: :resolved}) |> Repo.update!()

    Phoenix.PubSub.broadcast(Cinder.PubSub, "series", {:series_updated, series.id})

    assert_redirect(view, "/activity")
  end

  test "only persisted parsed coordinates can be promoted", %{conn: conn} do
    %{grab: grab, original: original, target: target, series: series} = held_mapping_fixture!()
    {:ok, view, _html} = live(conn, "/activity/grabs/#{grab.id}/mapping")

    assert has_element?(view, "#promote-coordinate-0-0-0")
    refute has_element?(view, "#mapping-file-1 [phx-click='promote']")

    view
    |> element("#mapping-form")
    |> render_change(save_params(target.id))

    view |> element("#promote-coordinate-0-0-1") |> render_click()

    assert has_element?(view, "#mapping-promotion-status", "Coordinate saved")
    assert [coordinate] = Catalog.list_episode_coordinates(series)
    assert coordinate.scheme == "absolute"
    assert coordinate.canonical_value == "12"
    assert Enum.map(coordinate.memberships, & &1.episode_id) == [target.id]
    assert Repo.get!(Grab, grab.id).mapping_status == :needs_mapping
    assert Repo.get!(Episode, original.id).grab_id == grab.id
  end

  test "cancel uses the existing remote cleanup fence", %{conn: conn} do
    %{grab: grab} = held_mapping_fixture!()

    expect(Cinder.Download.ClientMock, :remove, fn download_id, _opts ->
      assert download_id == grab.download_id
      :ok
    end)

    {:ok, view, _html} = live(conn, "/activity/grabs/#{grab.id}/mapping")
    view |> element("#ask-cancel-mapping") |> render_click()
    view |> element("#confirm-cancel-mapping button", "Cancel download") |> render_click()

    assert_redirect(view, "/activity")
    assert Repo.get(Grab, grab.id) == nil
  end

  test "localizes persisted mapping domain values", %{conn: conn} do
    grab = held_mapping_fixture!().grab
    conn = Plug.Conn.put_session(conn, :locale, "fr")

    {:ok, view, _html} = live(conn, "/activity/grabs/#{grab.id}/mapping")

    assert has_element?(view, "#mapping-issue", "Fichier non résolu")
    assert has_element?(view, "#mapping-file-0", "Absolu 11, 12")
    assert has_element?(view, "#mapping-file-0", "Rôle : histoire")
    assert has_element?(view, "#mapping-file-0-source", "Automatique")
    assert has_element?(view, "#mapping-file-0 [data-resolution]", "Ambigu")
    assert has_element?(view, "#mapping-file-0 [data-provenance]", "Manuel")
    assert has_element?(view, "#mapping-file-1 [data-resolution]", "Sans correspondance")
  end

  defp save_params(target_id) do
    %{
      "mapping" => %{
        "files" => %{
          "0" => %{
            "relative_path" => "Frieren - 11-12.mkv",
            "action" => "assign",
            "episode_ids" => [to_string(target_id)]
          },
          "1" => %{"relative_path" => "Extras/Frieren - NCOP.mkv", "action" => "ignore"}
        },
        "target_episode_ids" => [to_string(target_id)],
        "monitor_episode_ids" => []
      }
    }
  end

  defp held_mapping_fixture!(opts \\ []) do
    series = series_fixture(%{title: "Frieren", monitor_strategy: :all})
    season = season_fixture(series, season_number: 1)
    original = episode_fixture(season, episode_number: 1)

    target =
      episode_fixture(season,
        episode_number: 2,
        monitored: Keyword.get(opts, :target_monitored, true)
      )

    alternate = episode_fixture(season, episode_number: 3)

    decisions = %{
      "version" => 1,
      "files" => [
        %{
          "relative_path" => "Frieren - 11-12.mkv",
          "size" => 1_016,
          "major_device" => 1,
          "inode" => 116,
          "mtime" => 100,
          "parsed" => %{
            "coordinates" => [%{"scheme" => "absolute", "values" => ["11", "12"]}],
            "role" => "story",
            "group" => nil
          },
          "episode_ids" => [],
          "source" => "automatic",
          "ignored" => false,
          "evidence" => %{
            "resolution" => "ambiguous",
            "resolutions" => [
              %{
                "scheme" => "absolute",
                "canonical_value" => "11",
                "episode_ids" => [original.id],
                "resolver" => %{
                  "precedence" => "manual",
                  "matches" => [
                    %{
                      "coordinate" => %{
                        "source" => "fixture",
                        "namespace" => "main",
                        "scheme" => "absolute",
                        "canonical_value" => "11"
                      },
                      "episode_ids" => [original.id],
                      "evidence" => nil
                    }
                  ]
                }
              },
              %{
                "scheme" => "absolute",
                "canonical_value" => "12",
                "candidates" => [[target.id], [alternate.id]],
                "resolver" => %{
                  "precedence" => "manual",
                  "matches" => [
                    %{
                      "coordinate" => %{
                        "source" => "one",
                        "namespace" => "a",
                        "scheme" => "absolute",
                        "canonical_value" => "12"
                      },
                      "episode_ids" => [target.id],
                      "evidence" => nil
                    },
                    %{
                      "coordinate" => %{
                        "source" => "two",
                        "namespace" => "b",
                        "scheme" => "absolute",
                        "canonical_value" => "12"
                      },
                      "episode_ids" => [alternate.id],
                      "evidence" => nil
                    }
                  ]
                }
              }
            ]
          }
        },
        %{
          "relative_path" => "Extras/Frieren - NCOP.mkv",
          "size" => 500,
          "major_device" => 7,
          "inode" => 22,
          "mtime" => "2026-07-13T12:01:01",
          "parsed" => %{"coordinates" => [], "role" => "extra", "group" => nil},
          "episode_ids" => [],
          "source" => "automatic",
          "ignored" => false,
          "evidence" => %{"resolution" => "unmatched"}
        }
      ]
    }

    snapshot = %{
      "version" => 2,
      "reserved_episode_ids" => [original.id, target.id, alternate.id],
      "release" => %{
        "title" => "Frieren.01-02.1080p-GROUP",
        "coordinates" => [%{"scheme" => "absolute", "values" => ["1", "2"]}]
      }
    }

    grab =
      Repo.insert!(%Grab{
        download_id: "held-web-#{System.unique_integer([:positive])}",
        download_protocol: :torrent,
        release_title: "Frieren.01-02.1080p-GROUP",
        content_path: "/srv/downloads/anime/Frieren Pack",
        mapping_snapshot: snapshot,
        mapping_status: :needs_mapping,
        automatic_mapping_decisions: decisions,
        mapping_issue: %{
          "version" => 1,
          "reason" => "unresolved_file",
          "relative_paths" => ["Frieren - 11-12.mkv"],
          "candidate_episode_ids" => [target.id, alternate.id]
        }
      })

    original |> Ecto.Changeset.change(grab_id: grab.id) |> Repo.update!()
    target |> Ecto.Changeset.change(grab_id: grab.id) |> Repo.update!()
    alternate |> Ecto.Changeset.change(grab_id: grab.id) |> Repo.update!()

    %{
      grab: Repo.reload!(grab),
      original: original,
      target: target,
      alternate: alternate,
      series: series
    }
  end
end
