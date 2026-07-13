defmodule Cinder.Catalog.GrabMappingTest do
  use Cinder.DataCase, async: false

  import Mox

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Grab}
  alias Cinder.Download.Intent
  alias Cinder.Library
  alias Cinder.Repo

  import Cinder.CatalogFixtures

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
          "episode_ids" => [episode_id],
          "ignored" => false
        }
      ]
    }
  end
end
