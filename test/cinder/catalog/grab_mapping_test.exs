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
end
