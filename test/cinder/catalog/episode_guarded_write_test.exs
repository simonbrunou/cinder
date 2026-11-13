defmodule Cinder.Catalog.EpisodeGuardedWriteTest do
  # The episode writes #788 moved onto `Cinder.GuardedWrite` (finish, park, reap, grab creation,
  # adoption, file deletion): each committed change announces its series once, a finish or park
  # whose episodes another writer changed since the caller read them rolls back whole, and a
  # committed grab creation survives a failed announcement.
  #
  # Not async: `fail_broadcasts/0` swaps the adapter every PubSub broadcast in the node reads.
  use Cinder.DataCase, async: false

  import Mox
  import ExUnit.CaptureLog
  import Cinder.CatalogFixtures

  alias Cinder.Catalog
  alias Cinder.Catalog.{Episode, Grab}
  alias Cinder.Download.Intent
  alias Cinder.Repo

  setup :set_mox_global

  setup do
    stub(Cinder.Download.ClientMock, :remove, fn _id, _opts -> :ok end)
    stub(Cinder.Library.FilesystemMock, :rmdir, fn _path -> {:error, :enotempty} end)
    series = series_fixture(%{monitor_strategy: :all})
    season = season_fixture(series)
    %{series: series, season: season}
  end

  # A broadcast that raises, standing in for any failure after commit (a pool-checkout timeout on
  # the series lookup raises the same way).
  defmodule RaisingPubSubAdapter do
    def broadcast(_name, _topic, _message, _dispatcher), do: raise("pubsub unavailable")
  end

  describe "a committed change announces its series once" do
    test "a park of a season pack", %{series: series, season: season} do
      grab = season_pack(season, 2)
      announced_once(series, fn -> {:ok, _grab} = Catalog.park_grab(grab) end)
    end

    test "a park that also removes the client download", %{series: series, season: season} do
      grab = season_pack(season, 2)
      announced_once(series, fn -> {:ok, _grab} = Catalog.park_grab_and_remove(grab) end)
    end

    test "a finish that imports part of a season pack", %{series: series, season: season} do
      grab = season_pack(season, 2)
      [imported, _missing] = grab_episode_ids(grab)

      announced_once(series, fn ->
        {:ok, _grab} = Catalog.finish_grab(grab, [{imported, "/tv/Show/E01.mkv", nil}])
      end)
    end

    test "a stall reap of a season pack", %{series: series, season: season} do
      grab = season_pack(season, 2)
      announced_once(series, fn -> {:ok, _grab} = Catalog.reap_stalled_grab(grab) end)
    end

    test "an anime grab created from its intent", %{series: series, season: season} do
      intent = intent!([ep(season), ep(season)])
      announced_once(series, fn -> {:ok, _grab} = Catalog.create_grab_from_intent(intent) end)
    end

    test "deleting a file two episodes share", %{series: series, season: season} do
      path = "/tmp/Show.S01E01-E02.mkv"
      first = episode_fixture(season, %{episode_number: 1, file_path: path})
      _second = episode_fixture(season, %{episode_number: 2, file_path: path})
      expect(Cinder.Library.FilesystemMock, :rm, fn ^path -> :ok end)

      announced_once(series, fn -> {:ok, _updated} = Catalog.delete_episode_file(first, nil) end)
    end

    test "deleting a season's files", %{series: series, season: season} do
      for n <- 1..2,
          do: episode_fixture(season, %{episode_number: n, file_path: "/tmp/E#{n}.mkv"})

      stub(Cinder.Library.FilesystemMock, :rm, fn _path -> :ok end)

      announced_once(series, fn -> {:ok, 2, 0} = Catalog.delete_season_files(season, nil) end)
    end

    # Every unlink failed, so no episode row changed and the series is announced by hand.
    test "deleting a season's files when every unlink fails", %{series: series, season: season} do
      for n <- 1..2,
          do: episode_fixture(season, %{episode_number: n, file_path: "/tmp/E#{n}.mkv"})

      stub(Cinder.Library.FilesystemMock, :rm, fn _path -> {:error, :eacces} end)

      capture_log(fn ->
        announced_once(series, fn -> {:ok, 0, 2} = Catalog.delete_season_files(season, nil) end)
      end)
    end

    test "adopting files for two episodes", %{series: series, season: season} do
      actions = for n <- 1..2, do: primary_action(season, n)
      announced_once(series, fn -> {:ok, [_, _]} = Catalog.adopt_episode_files(actions) end)
    end

    test "adopting a series' files, which also assigns its profile", %{
      series: series,
      season: season
    } do
      actions = for n <- 1..2, do: primary_action(season, n)

      announced_once(series, fn ->
        {:ok, [_, _]} = adopt_series_files(series, actions)
      end)

      assert Repo.reload!(series).profile_id == standard_tv_profile().id
    end

    # The file is already the episode's, so only the profile changes and no episode is written.
    test "adopting a series' files the episodes already hold", %{series: series, season: season} do
      path = "/tmp/cinder-test-tv-library/Show/Show.S01E01.mkv"
      episode = episode_fixture(season, %{episode_number: 1, file_path: path})
      action = %{episode: episode, episode_code: "S01E01", type: :primary, path: path}

      announced_once(series, fn -> {:ok, [_]} = adopt_series_files(series, [action]) end)
      assert Repo.reload!(series).profile_id == standard_tv_profile().id
    end
  end

  describe "a finish or park whose episodes another writer changed since the caller read them" do
    # The bump would count from 0 where the row now holds 4: the write misses, the import of the
    # other episode rolls back with it, and nothing is announced.
    test "a finish rolls back whole", %{season: season} do
      grab = season |> season_pack(2) |> Repo.preload(:episodes)
      [imported, missing] = grab_episode_ids(grab)
      set_episode(missing, search_attempts: 4)
      Catalog.subscribe_series()

      assert Catalog.finish_grab(grab, [{imported, "/tv/Show/E01.mkv", nil}]) ==
               {:error, :stale_grab}

      refute_received {:series_updated, _}

      assert Repo.get(Grab, grab.id)
      assert %Episode{file_path: nil, grab_id: grab_id} = Repo.get!(Episode, imported)
      assert grab_id == grab.id
      assert %Episode{search_attempts: 4, grab_id: ^grab_id} = Repo.get!(Episode, missing)
    end

    test "a park rolls back whole", %{season: season} do
      grab = season |> season_pack(2) |> Repo.preload(:episodes)
      [first, second] = grab_episode_ids(grab)
      set_episode(second, monitored: false)
      Catalog.subscribe_series()

      assert Catalog.park_grab(grab) == {:error, :stale_grab}
      refute_received {:series_updated, _}
      assert Repo.get(Grab, grab.id)

      for id <- [first, second] do
        assert %Episode{search_attempts: 0, grab_id: grab_id} = Repo.get!(Episode, id)
        assert grab_id == grab.id
      end
    end
  end

  describe "a committed grab creation survives a failed announcement" do
    test "create_grab/5", %{season: season} do
      episode_ids = [ep(season), ep(season)]

      log =
        capture_log(fn ->
          fail_broadcasts(fn ->
            assert {:ok, %Grab{} = grab} =
                     Catalog.create_grab("hash-#{System.unique_integer()}", :torrent, episode_ids)

            send(self(), {:grab, grab})
          end)
        end)

      assert_received {:grab, grab}
      assert Repo.get(Grab, grab.id)
      assert Enum.sort(grab_episode_ids(grab)) == Enum.sort(episode_ids)
      assert log =~ "post-commit announce for episodes"
      assert log =~ "pubsub unavailable"
    end

    test "create_grab_from_intent/1", %{season: season} do
      episode_ids = [ep(season), ep(season)]
      intent = intent!(episode_ids)

      log =
        capture_log(fn ->
          fail_broadcasts(fn ->
            assert {:ok, %Grab{} = grab} = Catalog.create_grab_from_intent(intent)
            send(self(), {:grab, grab})
          end)
        end)

      assert_received {:grab, grab}
      assert Repo.get(Grab, grab.id)
      assert Enum.sort(grab_episode_ids(grab)) == Enum.sort(episode_ids)
      refute Repo.get(Intent, intent.id)
      assert log =~ "post-commit announce for episodes"
    end
  end

  defp announced_once(series, fun) do
    series_id = series.id
    Catalog.subscribe_series()
    fun.()
    assert_receive {:series_updated, ^series_id}
    refute_received {:series_updated, ^series_id}
  end

  # Every PubSub broadcast raises while `fun` runs. The adapter is node-wide state, restored on
  # exit too in case `fun` fails.
  defp fail_broadcasts(fun) do
    {:ok, {_adapter, name} = meta} = Registry.meta(Cinder.PubSub, :pubsub)
    on_exit(fn -> Registry.put_meta(Cinder.PubSub, :pubsub, meta) end)
    Registry.put_meta(Cinder.PubSub, :pubsub, {RaisingPubSubAdapter, name})

    try do
      fun.()
    after
      Registry.put_meta(Cinder.PubSub, :pubsub, meta)
    end
  end

  defp ep(season),
    do: episode_fixture(season, episode_number: System.unique_integer([:positive])).id

  defp season_pack(season, size) do
    episode_ids = for _ <- 1..size, do: ep(season)
    {:ok, grab} = Catalog.create_grab("pack-#{System.unique_integer()}", :torrent, episode_ids)
    grab
  end

  defp grab_episode_ids(grab),
    do: Repo.all(from e in Episode, where: e.grab_id == ^grab.id, order_by: e.id, select: e.id)

  defp set_episode(id, set), do: Repo.update_all(from(e in Episode, where: e.id == ^id), set: set)

  defp primary_action(season, n) do
    episode = episode_fixture(season, %{episode_number: n})
    path = "/tmp/cinder-test-tv-library/Show/Show.S01E0#{n}.mkv"
    %{episode: episode, episode_code: "S01E0#{n}", type: :primary, path: path}
  end

  defp adopt_series_files(series, actions),
    do:
      Catalog.adopt_series_files(series, actions, standard_tv_profile().id, :auto, fn _ -> :ok end)

  defp standard_tv_profile,
    do: Enum.find(Catalog.list_profiles(:tv), &(&1.handling == :standard))

  defp intent!(episode_ids) do
    Repo.insert!(%Intent{
      operation_key: Ecto.UUID.generate(),
      kind: :season_pack,
      target_id: hd(episode_ids),
      episode_ids: episode_ids,
      protocol: :torrent,
      release: %{"title" => "Anime.Release"},
      status: :submitted,
      remote_id: "anime-#{System.unique_integer([:positive])}",
      mapping_snapshot: %{"version" => 2, "reserved_episode_ids" => episode_ids}
    })
  end
end
