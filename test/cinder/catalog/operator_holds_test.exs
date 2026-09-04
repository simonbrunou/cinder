defmodule Cinder.Catalog.OperatorHoldsTest do
  use Cinder.DataCase, async: false

  alias Cinder.Catalog
  alias Cinder.Catalog.{Grab, GrabFile, Grabs, Movie}
  alias Cinder.Repo
  alias Cinder.TestNotifier

  import Cinder.CatalogFixtures

  # One undecided residual video keeps the source cleanup blocked (`insert_grab_files` shape).
  @residual %{
    relative_path: "extra.mkv",
    size: 10,
    device: 1,
    inode: 2,
    source: nil,
    scheme: nil,
    namespace: nil,
    canonical_value: nil
  }

  describe "count_operator_holds/0 — mirrors what /activity renders actions for" do
    test "is zero with nothing parked or held" do
      assert Catalog.count_operator_holds() == 0
    end

    test "counts each hold class once and excludes items with no operator action" do
      # Counted: a parked movie (Retry), a mapping hold, a verification hold, a residual grab.
      movie_fixture(status: :no_match)

      Repo.insert!(%Grab{
        download_id: "nm",
        download_protocol: :torrent,
        mapping_status: :needs_mapping
      })

      Repo.insert!(%Grab{
        download_id: "vb",
        download_protocol: :torrent,
        mapping_status: :verification_blocked
      })

      residual = Repo.insert!(%Grab{download_id: "res", download_protocol: :usenet})

      Repo.insert!(%GrabFile{
        grab_id: residual.id,
        relative_path: "x.mkv",
        size: 1,
        device: 1,
        inode: 1
      })

      # Not counted: an in-flight movie, an anime-held title (no action — the sweep clears it), a
      # resolved grab still downloading, and a resolved grab whose residuals are all decided.
      movie_fixture()
      held = movie_fixture()

      Repo.update!(
        Movie.anime_hold_changeset(held, %{anime_hold_reason: "subtitle_language_required"})
      )

      Repo.insert!(%Grab{
        download_id: "clean",
        download_protocol: :torrent,
        mapping_status: :resolved
      })

      decided = Repo.insert!(%Grab{download_id: "decided", download_protocol: :usenet})

      Repo.insert!(%GrabFile{
        grab_id: decided.id,
        relative_path: "y.mkv",
        size: 1,
        device: 2,
        inode: 3,
        decision: :fold
      })

      assert Catalog.count_operator_holds() == 4
    end
  end

  describe "grab_hold/1 — the per-grab hold classification /activity renders from" do
    test "classifies each hold class, nil when no operator action is needed" do
      assert Catalog.grab_hold(%Grab{mapping_status: :needs_mapping}) == :needs_mapping

      assert Catalog.grab_hold(%Grab{mapping_status: :verification_blocked}) ==
               :verification_blocked

      residual = %Grab{mapping_status: :resolved, grab_files: [%GrabFile{decision: nil}]}
      assert Catalog.grab_hold(residual) == :residual_files

      decided = %Grab{mapping_status: :resolved, grab_files: [%GrabFile{decision: :fold}]}
      assert Catalog.grab_hold(decided) == nil
      assert Catalog.grab_hold(%Grab{mapping_status: :resolved, grab_files: []}) == nil
    end

    test "a flagged mapping_status wins over residual files — one class per grab" do
      held = %Grab{mapping_status: :needs_mapping, grab_files: [%GrabFile{decision: nil}]}
      assert Catalog.grab_hold(held) == :needs_mapping
    end

    test "an unloaded grab_files association classifies as no residual hold" do
      assert Catalog.grab_hold(%Grab{mapping_status: :resolved}) == nil
      assert Catalog.unresolved_grab_files(%Grab{mapping_status: :resolved}) == []
    end

    test "unresolved_grab_files/1 keeps only the undecided residual videos" do
      undecided = %GrabFile{decision: nil}

      grab = %Grab{
        grab_files: [undecided, %GrabFile{decision: :fold}, %GrabFile{decision: :part}]
      }

      assert Catalog.unresolved_grab_files(grab) == [undecided]
    end

    test "count_grab_holds/0 agrees with classifying the listed grabs" do
      # One fixture per hold class, plus two non-holds (a clean downloading grab and a
      # residual grab whose files are all decided) — the SQL count is grab_hold/1 in query
      # form, so it must equal classifying what list_grabs/0 returns.
      Repo.insert!(%Grab{
        download_id: "nm",
        download_protocol: :torrent,
        mapping_status: :needs_mapping
      })

      Repo.insert!(%Grab{
        download_id: "vb",
        download_protocol: :torrent,
        mapping_status: :verification_blocked
      })

      residual = Repo.insert!(%Grab{download_id: "res", download_protocol: :usenet})

      Repo.insert!(%GrabFile{
        grab_id: residual.id,
        relative_path: "x.mkv",
        size: 1,
        device: 1,
        inode: 1
      })

      Repo.insert!(%Grab{
        download_id: "clean",
        download_protocol: :torrent,
        mapping_status: :resolved
      })

      decided = Repo.insert!(%Grab{download_id: "decided", download_protocol: :usenet})

      Repo.insert!(%GrabFile{
        grab_id: decided.id,
        relative_path: "y.mkv",
        size: 1,
        device: 2,
        inode: 3,
        decision: :fold
      })

      grabs = Catalog.list_grabs()

      assert Map.new(grabs, &{&1.download_id, Catalog.grab_hold(&1)}) == %{
               "nm" => :needs_mapping,
               "vb" => :verification_blocked,
               "res" => :residual_files,
               "clean" => nil,
               "decided" => nil
             }

      assert Grabs.count_grab_holds() == Enum.count(grabs, &(Catalog.grab_hold(&1) != nil))
    end

    # Regression for #459: list_grabs/0 used to have no limit at all, so bounding it risked
    # dropping an old operator hold below the cutoff — desynchronizing the nav badge
    # (count_grab_holds/0, unbounded) from what /activity actually lists and can act on. This
    # pins a hold older than the (test-shrunk) cap to still be listed, and the badge/page
    # agreement to still hold even once the table is well past the cap.
    test "an old operator hold is still listed past the recent-grabs cap, and the badge still agrees (#459)" do
      saved = Application.get_env(:cinder, Grabs, [])
      on_exit(fn -> Application.put_env(:cinder, Grabs, saved) end)
      Application.put_env(:cinder, Grabs, Keyword.put(saved, :list_grabs_limit, 2))

      Repo.insert!(%Grab{
        download_id: "old-hold",
        download_protocol: :torrent,
        mapping_status: :needs_mapping
      })

      for n <- 1..5 do
        Repo.insert!(%Grab{
          download_id: "clean-#{n}",
          download_protocol: :torrent,
          mapping_status: :resolved
        })
      end

      grabs = Catalog.list_grabs()

      # The cap (2) alone would have dropped "old-hold" (the oldest row); it is still present.
      assert "old-hold" in Enum.map(grabs, & &1.download_id)
      # Only the 2 most recent non-hold rows ride along with it — genuinely bounded, not "return
      # everything".
      assert Enum.map(grabs, & &1.download_id) |> Enum.sort() == [
               "clean-4",
               "clean-5",
               "old-hold"
             ]

      assert Grabs.count_grab_holds() == Enum.count(grabs, &(Catalog.grab_hold(&1) != nil))
    end
  end

  describe "{:operator_hold, grab, reason} is emitted once per new hold" do
    test "a fresh mapping hold notifies, a re-observation does not" do
      series = series_fixture(%{monitor_strategy: :all})
      episode = episode_fixture(season_fixture(series))
      {:ok, grab} = Catalog.create_grab("map-hash", :torrent, [episode.id])
      issue = %{"version" => 1, "reason" => "unresolved_file", "relative_paths" => ["a.mkv"]}

      TestNotifier.subscribe()

      assert {:ok, held} = Catalog.record_mapping_result(grab, {:needs_mapping, %{issue: issue}})
      assert_receive {:notify, {:operator_hold, hold_grab, :needs_mapping}}
      assert hold_grab.id == grab.id

      # Re-running the preflight on the still-held grab must not re-notify.
      assert {:ok, _} = Catalog.record_mapping_result(held, {:needs_mapping, %{issue: issue}})
      refute_receive {:notify, {:operator_hold, _, :needs_mapping}}
    end

    test "a verification hold notifies once" do
      series = series_fixture(%{monitor_strategy: :all})
      episode = episode_fixture(season_fixture(series))
      {:ok, grab} = Catalog.create_grab("ver-hash", :torrent, [episode.id])
      {:ok, _} = Catalog.mark_grab_downloaded(grab, "/downloads/ver")
      grab = Enum.find(Catalog.list_grabs_downloaded(), &(&1.id == grab.id))

      TestNotifier.subscribe()

      assert {:ok, held} = Catalog.hold_grab_verification(grab)
      assert_receive {:notify, {:operator_hold, hold_grab, :verification_blocked}}
      assert hold_grab.id == grab.id

      # Already blocked — the guard misses, no re-notify.
      assert {:error, :stale_grab} = Catalog.hold_grab_verification(held)
      refute_receive {:notify, {:operator_hold, _, :verification_blocked}}
    end

    test "persisting residual files notifies" do
      series = series_fixture(%{monitor_strategy: :all})
      episode = episode_fixture(season_fixture(series))
      {:ok, grab} = Catalog.create_grab("res-hash", :usenet, [episode.id])
      {:ok, _} = Catalog.mark_grab_downloaded(grab, "/downloads/res")
      grab = Enum.find(Catalog.list_grabs_downloaded(), &(&1.id == grab.id))

      TestNotifier.subscribe()

      assert {:ok, :open, _grab} = Catalog.commit_grab_imports(grab, [], [@residual], [])
      assert_receive {:notify, {:operator_hold, hold_grab, :residual_files}}
      assert hold_grab.id == grab.id
    end
  end
end
