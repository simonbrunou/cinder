defmodule Cinder.Catalog.GrabMappingTest do
  use Cinder.DataCase, async: false

  import Mox

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Grab}
  alias Cinder.Download.{Intent, IntentEpisode}
  alias Cinder.Library
  alias Cinder.Repo

  import Cinder.CatalogFixtures

  setup :set_mox_global
  setup :verify_on_exit!

  test "standard grabs default to resolved without mapping documents" do
    episode = episode_fixture(season_fixture(series_fixture(%{monitor_strategy: :all})))

    assert {:ok, grab} = Catalog.create_grab("standard-hash", :torrent, [episode.id])
    assert grab.mapping_status == :resolved
    assert grab.mapping_snapshot == nil
    assert grab.automatic_mapping_decisions == nil
    assert grab.manual_mapping_overrides == nil
    assert grab.mapping_issue == nil
  end

  test "a persisted mapping snapshot is immutable" do
    snapshot = %{"version" => 2}

    grab =
      %Grab{}
      |> Grab.reservation_changeset(%{
        download_id: "anime-hash",
        download_protocol: :torrent,
        mapping_snapshot: snapshot
      })
      |> Repo.insert!()

    changeset = Grab.reservation_changeset(grab, %{mapping_snapshot: %{"version" => 3}})

    assert "is immutable" in errors_on(changeset).mapping_snapshot
    assert Repo.reload(grab).mapping_snapshot == snapshot
  end

  test "an unknown mapping status is rejected" do
    changeset =
      Grab.reservation_changeset(%Grab{}, %{
        download_id: "anime-hash",
        download_protocol: :torrent,
        mapping_status: :unknown
      })

    refute changeset.valid?
    assert "is invalid" in errors_on(changeset).mapping_status
  end

  test "mapping updates cannot replace the reservation snapshot" do
    snapshot = %{"version" => 2}

    grab =
      Repo.insert!(%Grab{
        download_id: "anime-hash",
        download_protocol: :torrent,
        mapping_snapshot: snapshot
      })

    attrs = %{
      mapping_snapshot: %{"version" => 3},
      mapping_status: :needs_mapping,
      automatic_mapping_decisions: %{"file.mkv" => [1]},
      manual_mapping_overrides: %{"file.mkv" => [2]},
      mapping_issue: %{"reason" => "ambiguous"}
    }

    updated = grab |> Grab.mapping_changeset(attrs) |> Repo.update!()

    assert updated.mapping_snapshot == snapshot
    assert updated.mapping_status == :needs_mapping
    assert updated.automatic_mapping_decisions == attrs.automatic_mapping_decisions
    assert updated.manual_mapping_overrides == attrs.manual_mapping_overrides
    assert updated.mapping_issue == attrs.mapping_issue
  end

  test "create_grab_from_intent atomically copies the snapshot, links every reserved episode, and deletes the intent" do
    season = season_fixture(series_fixture(%{monitor_strategy: :all}))
    episode_a = episode_fixture(season, episode_number: 1)
    episode_b = episode_fixture(season, episode_number: 2)
    snapshot = %{"version" => 2, "reserved_episode_ids" => [episode_a.id, episode_b.id]}
    intent = snapshot_intent!([episode_a.id, episode_b.id], snapshot)

    assert {:ok, grab} = Catalog.create_grab_from_intent(intent)
    assert grab.mapping_snapshot == snapshot
    assert grab.mapping_status == :resolved
    assert Enum.sort(episode_ids(grab)) == Enum.sort([episode_a.id, episode_b.id])
    refute Repo.get(Intent, intent.id)
  end

  test "ownership conflict rolls back the grab and leaves the intent for cleanup" do
    season = season_fixture(series_fixture(%{monitor_strategy: :all}))
    episode_a = episode_fixture(season, episode_number: 1)
    episode_b = episode_fixture(season, episode_number: 2)
    snapshot = %{"version" => 2, "reserved_episode_ids" => [episode_a.id, episode_b.id]}
    intent = snapshot_intent!([episode_a.id, episode_b.id], snapshot)

    assert {:ok, _grab} = Catalog.create_grab("other-hash", :torrent, [episode_b.id])

    assert {:error, :episode_ownership_changed} = Catalog.create_grab_from_intent(intent)
    assert Repo.get!(Intent, intent.id)
    refute Repo.get_by(Grab, download_id: intent.remote_id)
    refute Repo.get!(Episode, episode_a.id).grab_id
  end

  describe "record_mapping_result/2" do
    test "persists resolved evidence and broadcasts exactly once" do
      series = series_fixture(%{monitor_strategy: :all})
      episode = episode_fixture(season_fixture(series))
      {:ok, grab} = Catalog.create_grab("resolved-hash", :torrent, [episode.id])
      decisions = decisions_document("Season 1/Frieren - 01.mkv", episode.id)
      series_id = series.id
      Catalog.subscribe_series()

      assert {:ok, resolved} = Catalog.record_mapping_result(grab, {:ok, %{decisions: decisions}})

      assert resolved.mapping_status == :resolved
      assert resolved.automatic_mapping_decisions == decisions
      assert resolved.mapping_issue == nil
      assert_receive {:series_updated, ^series_id}
      refute_received {:series_updated, ^series_id}

      json = Jason.encode!(resolved.automatic_mapping_decisions)
      refute json =~ "/downloads/anime"
    end

    test "a mapping hold only persists evidence and broadcasts" do
      series = series_fixture(%{monitor_strategy: :all})
      season = season_fixture(series)
      episode = episode_fixture(season, search_attempts: 4)

      {:ok, grab} =
        Catalog.create_grab(
          "held-hash",
          :torrent,
          [episode.id],
          "Frieren.01.1080p-GROUP"
        )

      decisions = decisions_document("Season 1/Frieren - 01.mkv", episode.id)

      issue = %{
        "version" => 1,
        "reason" => "ambiguous",
        "relative_paths" => ["Season 1/Frieren - 01.mkv"],
        "candidate_episode_ids" => [episode.id]
      }

      series_id = series.id
      Catalog.subscribe_series()

      assert {:ok, held} =
               Catalog.record_mapping_result(
                 grab,
                 {:needs_mapping, %{decisions: decisions, issue: issue}}
               )

      assert held.mapping_status == :needs_mapping
      assert held.automatic_mapping_decisions == decisions
      assert held.mapping_issue == issue
      assert_receive {:series_updated, ^series_id}
      refute_received {:series_updated, ^series_id}

      persisted_episode = Repo.get!(Episode, episode.id)
      assert Repo.get!(Grab, grab.id).id == grab.id
      assert persisted_episode.grab_id == grab.id
      assert persisted_episode.search_attempts == 4
      assert Catalog.blocked_release_titles_for_series(series.id) == []

      json =
        Jason.encode!(%{decisions: held.automatic_mapping_decisions, issue: held.mapping_issue})

      refute json =~ "/downloads/anime"
    end
  end

  describe "mapping recovery" do
    test "reads held mapping grabs with their series tree" do
      series = series_fixture(%{monitor_strategy: :all})
      season = season_fixture(series)
      first = episode_fixture(season, episode_number: 1)
      second = episode_fixture(season, episode_number: 2)
      held_a = held_grab_fixture!(first)
      held_b = held_grab_fixture!(second)

      other_episode =
        %{monitor_strategy: :all}
        |> series_fixture()
        |> season_fixture()
        |> episode_fixture()

      _other = held_grab_fixture!(other_episode)

      resolved =
        held_a
        |> Grab.mapping_changeset(%{mapping_status: :resolved})
        |> Repo.update!()

      loaded = Catalog.get_mapping_grab(resolved.id)
      assert Ecto.assoc_loaded?(loaded.episodes)
      assert hd(loaded.episodes).season.series.id == series.id
      assert Catalog.get_mapping_grab(-1) == nil

      assert [listed] = Catalog.list_mapping_grabs_for_series(series.id)
      assert listed.id == held_b.id
      assert Ecto.assoc_loaded?(listed.episodes)
      assert hd(listed.episodes).season.series.id == series.id
    end

    test "resume atomically replaces current targets and stores identity-bound overrides" do
      series = series_fixture(%{monitor_strategy: :all})
      season = season_fixture(series)
      episode_a = episode_fixture(season, episode_number: 1, search_attempts: 4)
      episode_b = episode_fixture(season, episode_number: 2)
      grab = held_grab_fixture!(episode_a)
      series_id = series.id
      Catalog.subscribe_series()

      assert {:ok, resumed} =
               Catalog.resume_grab_mapping(grab, %{
                 "files" => [
                   %{
                     "relative_path" => "Frieren - 28.mkv",
                     "size" => 999,
                     "major_device" => 999,
                     "inode" => 999,
                     "mtime" => "forged",
                     "evidence" => %{"forged" => true},
                     "action" => "assign",
                     "episode_ids" => [to_string(episode_b.id)]
                   }
                 ],
                 "target_episode_ids" => [to_string(episode_b.id)],
                 "monitor_episode_ids" => []
               })

      assert resumed.mapping_status == :resolved
      assert resumed.mapping_issue == nil
      assert resumed.mapping_snapshot == grab.mapping_snapshot
      assert resumed.automatic_mapping_decisions == grab.automatic_mapping_decisions

      assert resumed.manual_mapping_overrides == %{
               "version" => 1,
               "files" => [
                 %{
                   "relative_path" => "Frieren - 28.mkv",
                   "size" => 10,
                   "major_device" => 7,
                   "inode" => 21,
                   "mtime" => "2026-07-13T12:01:00",
                   "action" => "assign",
                   "episode_ids" => [episode_b.id]
                 }
               ],
               "original_episode_ids" => [episode_a.id],
               "target_episode_ids" => [episode_b.id],
               "monitor_episode_ids" => []
             }

      assert %Episode{grab_id: nil, search_attempts: 4, monitored: true} =
               Repo.get!(Episode, episode_a.id)

      assert Repo.get!(Episode, episode_b.id).grab_id == grab.id
      assert_receive {:series_updated, ^series_id}
      refute_received {:series_updated, ^series_id}
    end

    test "resume opts selected unmonitored targets in without touching other monitor flags" do
      series = series_fixture(%{monitor_strategy: :all})
      season = season_fixture(series)
      episode_a = episode_fixture(season, episode_number: 1)
      episode_b = episode_fixture(season, episode_number: 2, monitored: false)
      episode_c = episode_fixture(season, episode_number: 3, monitored: false)
      grab = held_grab_fixture!(episode_a)

      assert {:ok, _resumed} =
               Catalog.resume_grab_mapping(
                 grab,
                 resume_attrs(episode_b.id, monitor_episode_ids: [episode_b.id])
               )

      assert Repo.get!(Episode, episode_b.id).monitored
      refute Repo.get!(Episode, episode_c.id).monitored
    end

    test "resume rolls back for a target in another series" do
      {grab, original, _same_series_target} = recovery_fixture()

      foreign =
        %{monitor_strategy: :all}
        |> series_fixture()
        |> season_fixture()
        |> episode_fixture()

      assert_resume_rejected(grab, original, resume_attrs(foreign.id))
      assert Repo.get!(Episode, foreign.id).grab_id == nil
    end

    test "resume rolls back for an already available target" do
      {grab, original, target} = recovery_fixture(%{file_path: "/library/Frieren 28.mkv"})

      assert_resume_rejected(grab, original, resume_attrs(target.id))
      assert Repo.get!(Episode, target.id).file_path == "/library/Frieren 28.mkv"
    end

    test "resume rolls back for a target owned by another grab" do
      {grab, original, target} = recovery_fixture()
      assert {:ok, owner} = Catalog.create_grab("other-owner", :torrent, [target.id])

      assert_resume_rejected(grab, original, resume_attrs(target.id))
      assert Repo.get!(Episode, target.id).grab_id == owner.id
    end

    test "resume rolls back for a target reserved by an active intent" do
      {grab, original, target} = recovery_fixture()
      intent = reserved_intent_fixture!(target)

      assert_resume_rejected(grab, original, resume_attrs(target.id))
      assert Repo.get!(Intent, intent.id)
      assert Repo.get!(Episode, target.id).grab_id == nil
    end

    test "resume rolls back for an unmonitored target without explicit opt-in" do
      {grab, original, target} = recovery_fixture(%{monitored: false})

      assert_resume_rejected(grab, original, resume_attrs(target.id))
      refute Repo.get!(Episode, target.id).monitored
    end

    test "resume rejects duplicate episode IDs without changing held state" do
      {grab, original, target} = recovery_fixture()

      for attrs <- [
            resume_attrs(target.id, target_episode_ids: [target.id, to_string(target.id)]),
            resume_attrs(target.id, monitor_episode_ids: [target.id, target.id]),
            resume_attrs(target.id,
              episode_ids: [target.id, target.id],
              monitor_episode_ids: []
            )
          ] do
        assert_resume_rejected(grab, original, attrs)
      end
    end

    test "resume rejects an empty target set without changing held state" do
      {grab, original, _target} = recovery_fixture()

      assert_resume_rejected(grab, original, %{
        "files" => [%{"relative_path" => "Frieren - 28.mkv", "action" => "ignore"}],
        "target_episode_ids" => [],
        "monitor_episode_ids" => []
      })
    end

    test "resume rejects a missing target without changing held state or broadcasting" do
      {grab, original, _target} = recovery_fixture()
      missing_id = System.unique_integer([:positive]) + 1_000_000_000

      assert :episode_not_found =
               assert_resume_rejected(grab, original, resume_attrs(missing_id))
    end

    test "resume rejects a deleted grab" do
      {grab, original, target} = recovery_fixture()
      series_id = original |> Repo.preload(season: :series) |> then(& &1.season.series.id)
      Catalog.subscribe_series()
      Repo.delete!(grab)

      assert {:error, :stale_grab} = Catalog.resume_grab_mapping(grab, resume_attrs(target.id))
      assert Repo.get!(Episode, original.id).grab_id == nil
      assert Repo.get!(Episode, target.id).grab_id == nil
      refute_received {:series_updated, ^series_id}
    end

    test "resume rejects a grab that is no longer held" do
      {grab, original, target} = recovery_fixture()
      resolved = grab |> Grab.mapping_changeset(%{mapping_status: :resolved}) |> Repo.update!()

      assert_resume_rejected(resolved, original, resume_attrs(target.id))
      assert Repo.get!(Grab, grab.id).mapping_status == :resolved
    end

    test "a resume winning after a held read cannot be followed by stale cancellation" do
      {grab, original, target} = recovery_fixture()
      parent = self()

      stub(Cinder.Download.ClientMock, :remove, fn remote_id, opts ->
        send(parent, {:remote_remove, remote_id, opts})
        :ok
      end)

      cancel =
        Task.async(fn ->
          held = Catalog.get_mapping_grab(grab.id)
          send(parent, {:held_read, self()})

          receive do
            :cancel -> Catalog.cancel_mapping_grab(held)
          end
        end)

      assert_receive {:held_read, cancel_pid}
      assert cancel_pid == cancel.pid
      assert {:ok, resumed} = Catalog.resume_grab_mapping(grab, resume_attrs(target.id))
      send(cancel.pid, :cancel)

      assert {:error, :mapping_not_held} = Task.await(cancel)
      assert Repo.get!(Grab, grab.id).mapping_status == :resolved
      assert Repo.get!(Episode, original.id).grab_id == nil
      assert Repo.get!(Episode, target.id).grab_id == resumed.id
      assert Repo.aggregate(Intent, :count) == 0
      assert Repo.aggregate(IntentEpisode, :count) == 0
      refute_received {:remote_remove, _, [delete_files: true]}
    end

    test "resume rejects unknown or duplicate persisted file paths" do
      {grab, original, target} = recovery_fixture()
      attrs = resume_attrs(target.id)

      unknown =
        put_in(attrs, ["files", Access.at(0), "relative_path"], "Unknown - 28.mkv")

      duplicate = Map.update!(attrs, "files", fn [file] -> [file, file] end)

      assert_resume_rejected(grab, original, unknown)
      assert_resume_rejected(grab, original, duplicate)
    end

    test "resume rejects malformed actions and assignments" do
      {grab, original, target} = recovery_fixture()
      attrs = resume_attrs(target.id)

      malformed = put_in(attrs, ["files", Access.at(0), "action"], "rename")
      empty_assignment = put_in(attrs, ["files", Access.at(0), "episode_ids"], [])
      invalid_id = put_in(attrs, ["files", Access.at(0), "episode_ids"], [0])

      assert_resume_rejected(grab, original, malformed)
      assert_resume_rejected(grab, original, empty_assignment)
      assert_resume_rejected(grab, original, invalid_id)
    end

    test "resume rejects assignments and monitor additions outside the target set" do
      {grab, original, target} = recovery_fixture()

      season =
        Repo.get!(Episode, target.id).season_id |> then(&Repo.get!(Cinder.Catalog.Season, &1))

      outside = episode_fixture(season, episode_number: 3)

      assignment_outside =
        resume_attrs(target.id, episode_ids: [outside.id], monitor_episode_ids: [])

      monitor_outside = resume_attrs(target.id, monitor_episode_ids: [outside.id])

      assert_resume_rejected(grab, original, assignment_outside)
      assert_resume_rejected(grab, original, monitor_outside)
      assert Repo.get!(Episode, outside.id).grab_id == nil
    end

    test "resume rolls back when target ownership changes after validation" do
      {grab, original, target} = recovery_fixture()

      competing_grab =
        Repo.insert!(%Grab{
          download_id: "racing-owner",
          download_protocol: :torrent
        })

      trigger = "mapping_target_ownership_race"

      Repo.query!("""
      CREATE TEMP TRIGGER #{trigger}
      AFTER UPDATE OF grab_id ON episodes
      WHEN OLD.id = #{original.id} AND NEW.grab_id IS NULL
      BEGIN
        UPDATE episodes SET grab_id = #{competing_grab.id} WHERE id = #{target.id};
      END
      """)

      before = mapping_documents(grab)
      series_id = original |> Repo.preload(season: :series) |> then(& &1.season.series.id)
      Catalog.subscribe_series()

      try do
        assert {:error, :episode_ownership_changed} =
                 Catalog.resume_grab_mapping(grab, resume_attrs(target.id))

        assert mapping_documents(Repo.get!(Grab, grab.id)) == before
        assert Repo.get!(Episode, original.id).grab_id == grab.id
        assert Repo.get!(Episode, target.id).grab_id == nil
        refute_received {:series_updated, ^series_id}
      after
        Repo.query!("DROP TRIGGER IF EXISTS #{trigger}")
      end
    end
  end

  describe "mapping identity promotion" do
    test "promotes one persisted parsed coordinate with explicit episode order" do
      series = series_fixture(%{monitor_strategy: :all})
      season = season_fixture(series)
      first = episode_fixture(season, episode_number: 1)
      second = episode_fixture(season, episode_number: 2)
      grab = held_grab_fixture!(first)
      before = mapping_documents(grab)
      series_id = series.id
      Catalog.subscribe_series()

      assert {:ok, coordinate} =
               Catalog.promote_grab_mapping(grab, %{
                 "relative_path" => "Frieren - 28.mkv",
                 "scheme" => "absolute",
                 "value" => "28",
                 "episode_ids" => [to_string(second.id), first.id]
               })

      assert coordinate.source == "manual"
      assert coordinate.scheme == "absolute"
      assert coordinate.namespace == "mapping-recovery"
      assert coordinate.canonical_value == "28"
      assert coordinate.precedence == :manual
      assert Enum.map(coordinate.memberships, & &1.episode_id) == [second.id, first.id]
      assert mapping_documents(Repo.get!(Grab, grab.id)) == before
      assert_receive {:series_updated, ^series_id}
      refute_received {:series_updated, ^series_id}
    end

    test "promotion rejects an unknown or non-reusable persisted decision" do
      {grab, _original, _target} = recovery_fixture()
      series_id = hd(Repo.preload(grab, episodes: [season: :series]).episodes).season.series.id
      Catalog.subscribe_series()

      assert {:error, _reason} =
               Catalog.promote_grab_mapping(grab, %{
                 "relative_path" => "Unknown.mkv",
                 "scheme" => "absolute",
                 "value" => "28",
                 "episode_ids" => episode_ids(grab)
               })

      assert {:error, _reason} =
               Catalog.promote_grab_mapping(grab, %{
                 "relative_path" => "Frieren - 28.mkv",
                 "scheme" => "absolute",
                 "value" => "29",
                 "episode_ids" => episode_ids(grab)
               })

      series = hd(Repo.preload(grab, episodes: [season: :series]).episodes).season.series
      assert Catalog.list_episode_coordinates(series) == []
      refute_received {:series_updated, ^series_id}
    end

    test "promotion rejects foreign, duplicate, or empty episode selections" do
      {grab, original, target} = recovery_fixture()

      foreign =
        %{monitor_strategy: :all}
        |> series_fixture()
        |> season_fixture()
        |> episode_fixture()

      attrs = %{
        "relative_path" => "Frieren - 28.mkv",
        "scheme" => "absolute",
        "value" => "28"
      }

      assert {:error, _reason} =
               Catalog.promote_grab_mapping(grab, Map.put(attrs, "episode_ids", [foreign.id]))

      assert {:error, _reason} =
               Catalog.promote_grab_mapping(
                 grab,
                 Map.put(attrs, "episode_ids", [target.id, target.id])
               )

      assert {:error, _reason} =
               Catalog.promote_grab_mapping(grab, Map.put(attrs, "episode_ids", []))

      series = Repo.get!(Cinder.Catalog.Season, original.season_id) |> Repo.preload(:series)
      assert Catalog.list_episode_coordinates(series.series) == []
    end

    test "promotion re-reads and rejects a grab that is no longer held" do
      {grab, _original, target} = recovery_fixture()
      before = mapping_documents(grab)
      grab |> Grab.mapping_changeset(%{mapping_status: :resolved}) |> Repo.update!()

      assert {:error, :mapping_not_held} =
               Catalog.promote_grab_mapping(grab, %{
                 "relative_path" => "Frieren - 28.mkv",
                 "scheme" => "absolute",
                 "value" => "28",
                 "episode_ids" => [target.id]
               })

      persisted = Repo.get!(Grab, grab.id)

      assert Map.take(mapping_documents(persisted), [:snapshot, :overrides]) ==
               Map.take(before, [:snapshot, :overrides])
    end

    test "promotion rejects a deleted grab without creating a coordinate" do
      {grab, original, target} = recovery_fixture()
      series = original |> Repo.preload(season: :series) |> then(& &1.season.series)
      Repo.delete!(grab)

      assert {:error, :stale_grab} =
               Catalog.promote_grab_mapping(grab, %{
                 "relative_path" => "Frieren - 28.mkv",
                 "scheme" => "absolute",
                 "value" => "28",
                 "episode_ids" => [target.id]
               })

      assert Catalog.list_episode_coordinates(series) == []
    end

    @tag :unboxed
    test "promotion holds an immediate write gate from held-state read through identity write" do
      series = series_fixture(%{monitor_strategy: :all})
      season = season_fixture(series)
      first = episode_fixture(season, episode_number: 1)
      second = episode_fixture(season, episode_number: 2)
      grab = held_grab_fixture!(first)
      database = Application.fetch_env!(:cinder, Cinder.Repo) |> Keyword.fetch!(:database)
      {:ok, racer} = Exqlite.Sqlite3.open(database)
      :ok = Exqlite.Sqlite3.set_busy_timeout(racer, 0)
      handler_id = {__MODULE__, self(), make_ref()}
      test_process = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:cinder, :repo, :query],
          fn _event, _measurements, metadata, {owner, connection, grab_id, marker} ->
            if self() == owner and metadata.source == "episodes" and
                 not Process.get(marker, false) do
              Process.put(marker, true)

              result =
                Exqlite.Sqlite3.execute(
                  connection,
                  "UPDATE grabs SET mapping_status = 'resolved' WHERE id = #{grab_id}"
                )

              send(owner, {:promotion_race, result})
            end
          end,
          {test_process, racer, grab.id, handler_id}
        )

      try do
        assert {:ok, _coordinate} =
                 Catalog.promote_grab_mapping(grab, %{
                   "relative_path" => "Frieren - 28.mkv",
                   "scheme" => "absolute",
                   "value" => "28",
                   "episode_ids" => [second.id]
                 })

        assert_receive {:promotion_race, {:error, reason}}
        assert to_string(reason) =~ ~r/busy|locked/i
        assert Repo.get!(Grab, grab.id).mapping_status == :needs_mapping
      after
        :telemetry.detach(handler_id)
        Exqlite.Sqlite3.close(racer)
        Repo.delete_all(from g in Grab, where: g.id == ^grab.id)
        Repo.delete_all(from s in Cinder.Catalog.Series, where: s.id == ^series.id)
      end
    end
  end

  test "preflight_anime_grab inventories, resolves overrides, and persists before staging" do
    series = series_fixture(%{monitor_strategy: :all})
    season = season_fixture(series)
    episode = episode_fixture(season, episode_number: 1)
    source = "/tmp/downloads/Frieren - 01.mkv"
    mtime = "2026-07-13T12:01:00"

    override = %{
      "relative_path" => "Frieren - 01.mkv",
      "size" => 10,
      "major_device" => 7,
      "inode" => 21,
      "mtime" => mtime,
      "action" => "assign",
      "episode_ids" => [episode.id]
    }

    grab =
      Repo.insert!(%Grab{
        download_id: "preflight-hash",
        download_protocol: :torrent,
        content_path: source,
        mapping_snapshot: %{"version" => 1},
        manual_mapping_overrides: %{"files" => [override]}
      })

    episode |> Ecto.Changeset.change(grab_id: grab.id) |> Repo.update!()
    grab = Repo.preload(grab, episodes: :season)

    stub(Cinder.Library.FilesystemMock, :dir?, fn ^source -> false end)

    expect(Cinder.Library.FilesystemMock, :lstat, fn ^source ->
      {:ok,
       %File.Stat{
         type: :regular,
         size: 10,
         major_device: 7,
         inode: 21,
         mtime: {{2026, 7, 13}, {12, 1, 0}}
       }}
    end)

    series_id = series.id
    Catalog.subscribe_series()

    assert {:ok, %{grab: persisted, folder?: false, assignments: [assignment]}} =
             Library.preflight_anime_grab(grab)

    assert assignment == %{relative_path: "Frieren - 01.mkv", episode_ids: [episode.id]}
    assert persisted.mapping_status == :resolved
    assert_receive {:series_updated, ^series_id}

    json = Jason.encode!(persisted.automatic_mapping_decisions)
    refute json =~ "/tmp/downloads"
  end

  defp snapshot_intent!(episode_ids, snapshot) do
    Repo.insert!(%Intent{
      operation_key: Ecto.UUID.generate(),
      kind: if(length(episode_ids) == 1, do: :episode, else: :season_pack),
      target_id: hd(episode_ids),
      episode_ids: episode_ids,
      protocol: :torrent,
      release: %{"title" => "Anime.Release"},
      status: :submitted,
      remote_id: "anime-#{System.unique_integer([:positive])}",
      mapping_snapshot: snapshot
    })
  end

  defp episode_ids(grab) do
    Repo.all(from e in Episode, where: e.grab_id == ^grab.id, select: e.id)
  end

  defp decisions_document(relative_path, episode_id) do
    %{
      "version" => 1,
      "files" => [
        %{
          "relative_path" => relative_path,
          "size" => 10,
          "major_device" => 7,
          "inode" => 21,
          "mtime" => "2026-07-13T12:01:00",
          "parsed" => %{
            "coordinates" => [%{"scheme" => "absolute", "values" => ["28"]}],
            "role" => "main",
            "group" => nil
          },
          "episode_ids" => [episode_id],
          "source" => "automatic",
          "ignored" => false
        }
      ]
    }
  end

  defp held_grab_fixture!(episode, opts \\ []) do
    snapshot =
      Keyword.get(opts, :snapshot, %{"version" => 2, "reserved_episode_ids" => [episode.id]})

    decisions =
      Keyword.get(opts, :decisions, decisions_document("Frieren - 28.mkv", episode.id))

    grab =
      Repo.insert!(%Grab{
        download_id: "held-#{System.unique_integer([:positive])}",
        download_protocol: :torrent,
        mapping_snapshot: snapshot,
        mapping_status: Keyword.get(opts, :mapping_status, :needs_mapping),
        automatic_mapping_decisions: decisions,
        manual_mapping_overrides: %{"version" => 1, "files" => []},
        mapping_issue: %{"version" => 1, "reason" => "ambiguous"}
      })

    episode |> Ecto.Changeset.change(grab_id: grab.id) |> Repo.update!()
    Repo.preload(grab, episodes: [season: :series])
  end

  defp recovery_fixture(target_attrs \\ %{}) do
    series = series_fixture(%{monitor_strategy: :all})
    season = season_fixture(series)
    original = episode_fixture(season, episode_number: 1, search_attempts: 3)
    target = episode_fixture(season, Map.merge(%{episode_number: 2}, target_attrs))
    {held_grab_fixture!(original), original, target}
  end

  defp resume_attrs(target_id, opts \\ []) do
    episode_ids = Keyword.get(opts, :episode_ids, [target_id])
    target_episode_ids = Keyword.get(opts, :target_episode_ids, [target_id])
    monitor_episode_ids = Keyword.get(opts, :monitor_episode_ids, [])

    %{
      "files" => [
        %{
          "relative_path" => "Frieren - 28.mkv",
          "action" => "assign",
          "episode_ids" => episode_ids
        }
      ],
      "target_episode_ids" => target_episode_ids,
      "monitor_episode_ids" => monitor_episode_ids
    }
  end

  defp assert_resume_rejected(grab, original, attrs) do
    before = mapping_documents(Repo.get!(Grab, grab.id))
    original_links = episode_ids(grab)
    series_id = original |> Repo.preload(season: :series) |> then(& &1.season.series.id)
    Catalog.subscribe_series()

    assert {:error, reason} = Catalog.resume_grab_mapping(grab, attrs)

    persisted = Repo.get!(Grab, grab.id)
    assert mapping_documents(persisted) == before
    assert episode_ids(grab) == original_links
    assert Repo.get!(Episode, original.id).grab_id == grab.id
    refute_received {:series_updated, ^series_id}
    reason
  end

  defp mapping_documents(grab) do
    Map.take(grab, [
      :mapping_snapshot,
      :mapping_status,
      :automatic_mapping_decisions,
      :manual_mapping_overrides,
      :mapping_issue
    ])
    |> Map.new(fn
      {:mapping_snapshot, value} -> {:snapshot, value}
      {:manual_mapping_overrides, value} -> {:overrides, value}
      pair -> pair
    end)
  end

  defp reserved_intent_fixture!(episode) do
    intent =
      Repo.insert!(%Intent{
        operation_key: Ecto.UUID.generate(),
        kind: :episode,
        target_id: episode.id,
        episode_ids: [episode.id],
        protocol: :torrent,
        release: %{"title" => "Reserved.Release"},
        status: :reserved
      })

    Repo.insert!(%IntentEpisode{intent_id: intent.id, episode_id: episode.id})
    intent
  end
end
