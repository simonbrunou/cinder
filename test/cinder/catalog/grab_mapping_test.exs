defmodule Cinder.Catalog.GrabMappingTest do
  use Cinder.DataCase, async: false

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Grab}
  alias Cinder.Download.Intent
  alias Cinder.Repo

  import Cinder.CatalogFixtures

  test "standard grabs default to resolved without mapping documents" do
    episode = episode_fixture(season_fixture(series_fixture(%{monitor_strategy: :all})))

    assert {:ok, grab} = Catalog.create_grab("standard-hash", :torrent, [episode.id])
    assert grab.mapping_status == :resolved
    assert grab.mapping_snapshot == nil
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
      mapping_issue: %{"reason" => "ambiguous"}
    }

    updated = grab |> Grab.mapping_changeset(attrs) |> Repo.update!()

    assert updated.mapping_snapshot == snapshot
    assert updated.mapping_status == :needs_mapping
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
    test "persists a resolved outcome and broadcasts exactly once" do
      series = series_fixture(%{monitor_strategy: :all})
      episode = episode_fixture(season_fixture(series))
      {:ok, grab} = Catalog.create_grab("resolved-hash", :torrent, [episode.id])
      series_id = series.id
      Catalog.subscribe_series()

      assert {:ok, resolved} = Catalog.record_mapping_result(grab, {:ok, %{}})

      assert resolved.mapping_status == :resolved
      assert resolved.mapping_issue == nil
      assert_receive {:series_updated, ^series_id}
      refute_received {:series_updated, ^series_id}
    end

    test "a mapping hold persists its reason and broadcasts, without touching the episode" do
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

      issue = %{
        "version" => 1,
        "reason" => "unresolved_file",
        "relative_paths" => ["Season 1/Frieren - 01.mkv"],
        "candidate_episode_ids" => []
      }

      series_id = series.id
      Catalog.subscribe_series()

      assert {:ok, held} = Catalog.record_mapping_result(grab, {:needs_mapping, %{issue: issue}})

      assert held.mapping_status == :needs_mapping
      assert held.mapping_issue == issue
      assert_receive {:series_updated, ^series_id}
      refute_received {:series_updated, ^series_id}

      persisted_episode = Repo.get!(Episode, episode.id)
      assert Repo.get!(Grab, grab.id).id == grab.id
      assert persisted_episode.grab_id == grab.id
      assert persisted_episode.search_attempts == 4
      assert Catalog.blocked_release_titles_for_series(series.id) == []
    end
  end

  describe "mapping holds" do
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

      assert Catalog.get_mapping_grab(resolved.id) == nil

      loaded = Catalog.get_mapping_grab(held_b.id)
      assert Ecto.assoc_loaded?(loaded.episodes)
      assert hd(loaded.episodes).season.series.id == series.id
      assert Catalog.get_mapping_grab(-1) == nil

      assert [listed] = Catalog.list_mapping_grabs_for_series(series.id)
      assert listed.id == held_b.id
      assert Ecto.assoc_loaded?(listed.episodes)
      assert hd(listed.episodes).season.series.id == series.id
    end

    test "cancel_mapping_grab discards a held grab and frees its episode back to wanted" do
      series = series_fixture(%{monitor_strategy: :all})
      season = season_fixture(series)
      episode = episode_fixture(season, episode_number: 1, search_attempts: 3)
      grab = held_grab_fixture!(episode)
      series_id = series.id
      Catalog.subscribe_series()

      assert {:ok, _deleted} = Catalog.cancel_mapping_grab(grab)

      refute Repo.get(Grab, grab.id)
      reloaded = Repo.get!(Episode, episode.id)
      assert reloaded.grab_id == nil
      assert reloaded.monitored
      assert reloaded.file_path == nil
      assert_receive {:series_updated, ^series_id}
    end

    test "cancel_mapping_grab rejects a grab that is not held" do
      series = series_fixture(%{monitor_strategy: :all})
      episode = episode_fixture(season_fixture(series))
      {:ok, grab} = Catalog.create_grab("resolved-cancel", :torrent, [episode.id])

      assert {:error, :mapping_not_held} = Catalog.cancel_mapping_grab(grab)
      assert Repo.get!(Grab, grab.id)
    end
  end

  describe "retry_grab_mapping/1" do
    test "releases a held grab back to resolved and resets the attempt counter" do
      series = series_fixture(%{monitor_strategy: :all})
      episode = episode_fixture(season_fixture(series))
      grab = held_grab_fixture!(episode)

      Repo.update_all(from(g in Grab, where: g.id == ^grab.id), set: [download_attempts: 7])
      grab = Repo.get!(Grab, grab.id)

      series_id = series.id
      Catalog.subscribe_series()

      assert {:ok, retried} = Catalog.retry_grab_mapping(grab)

      assert retried.mapping_status == :resolved
      assert retried.download_attempts == 0
      assert_receive {:series_updated, ^series_id}
    end

    test "rejects a grab that is not held for mapping" do
      series = series_fixture(%{monitor_strategy: :all})
      episode = episode_fixture(season_fixture(series))
      {:ok, grab} = Catalog.create_grab("resolved-retry", :torrent, [episode.id])

      assert {:error, :mapping_not_held} = Catalog.retry_grab_mapping(grab)
    end

    test "rejects a stale read of an already-retried grab" do
      series = series_fixture(%{monitor_strategy: :all})
      episode = episode_fixture(season_fixture(series))
      grab = held_grab_fixture!(episode)

      assert {:ok, retried} = Catalog.retry_grab_mapping(grab)
      assert {:error, :mapping_not_held} = Catalog.retry_grab_mapping(grab)
      assert Repo.get!(Grab, grab.id).id == retried.id
    end
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

  defp held_grab_fixture!(episode) do
    grab =
      Repo.insert!(%Grab{
        download_id: "held-#{System.unique_integer([:positive])}",
        download_protocol: :torrent,
        mapping_snapshot: %{"version" => 2, "reserved_episode_ids" => [episode.id]},
        mapping_status: :needs_mapping,
        mapping_issue: %{"version" => 1, "reason" => "ambiguous"}
      })

    episode |> Ecto.Changeset.change(grab_id: grab.id) |> Repo.update!()
    Repo.preload(grab, episodes: [season: :series])
  end
end
