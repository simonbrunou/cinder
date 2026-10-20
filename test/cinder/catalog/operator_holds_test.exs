defmodule Cinder.Catalog.OperatorHoldsTest do
  use Cinder.DataCase, async: false

  alias Cinder.Catalog
  alias Cinder.Catalog.{Attention, Grab, Grabs}
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

  describe "list_grabs/0 keeps every grab that needs attention" do
    # Regression for #459: list_grabs/0 used to have no limit at all, so bounding it risked
    # dropping an old operator hold below the cutoff — desynchronizing the nav badge
    # (`Attention.counts/0`, unbounded) from what /activity actually lists and can act on. This
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

      assert Attention.counts().grab.attention ==
               Enum.count(grabs, &(Attention.classify(&1).phase == :attention))
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
